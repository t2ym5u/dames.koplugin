-- ---------------------------------------------------------------------------
-- CheckersBoard — game logic for Jeu de Dames francaises (8x8)
--
-- board[r][c]:
--   0 = empty
--   1 = white man   (W_MAN)
--   2 = white king  (W_KING)
--   3 = black man   (B_MAN)
--   4 = black king  (B_KING)
--
-- Dark squares: (r+c) % 2 == 1  (1-indexed, r=1 top, c=1 left)
-- Initial: black men rows 1-3 dark squares; white men rows 6-8 dark squares
-- White moves UP (decreasing r), black moves DOWN (increasing r)
-- ---------------------------------------------------------------------------

local UndoStack = require("undo_stack")

local CheckersBoard = {}
CheckersBoard.__index = CheckersBoard

CheckersBoard.W_MAN  = 1
CheckersBoard.W_KING = 2
CheckersBoard.B_MAN  = 3
CheckersBoard.B_KING = 4

local INF = 1e9

-- ---------------------------------------------------------------------------
-- Constructor
-- ---------------------------------------------------------------------------

function CheckersBoard:new(opts)
    opts = opts or {}
    local o = setmetatable({}, self)
    o.board      = {}
    o.turn       = "white"
    o.selected   = nil
    o.won        = nil
    o.chain      = nil        -- {r, c} if mid-chain capture
    o.chain_kills = {}        -- set of "r_c" keys of already-captured pieces this chain
    o._moves     = {}         -- cached list of all legal moves for current turn
    o._undo      = UndoStack:new{ max_size = 200 }
    o.style      = (opts and opts.style) or "french"  -- "french" or "english"
    for r = 1, 8 do
        o.board[r] = {}
        for c = 1, 8 do
            o.board[r][c] = 0
        end
    end
    return o
end

-- ---------------------------------------------------------------------------
-- Board setup
-- ---------------------------------------------------------------------------

function CheckersBoard:reset()
    for r = 1, 8 do
        for c = 1, 8 do
            local dark = (r + c) % 2 == 1
            if dark then
                if r <= 3 then
                    self.board[r][c] = self.B_MAN
                elseif r >= 6 then
                    self.board[r][c] = self.W_MAN
                else
                    self.board[r][c] = 0
                end
            else
                self.board[r][c] = 0
            end
        end
    end
    self.turn       = "white"
    self.selected   = nil
    self.won        = nil
    self.chain      = nil
    self.chain_kills = {}
    self._undo:clear()
    self:updateMoves()
end

function CheckersBoard:generate()
    self:reset()
end

-- ---------------------------------------------------------------------------
-- Move generation
-- ---------------------------------------------------------------------------

local function isWhite(v)
    return v == 1 or v == 2
end

local function isBlack(v)
    return v == 3 or v == 4
end

local function isKing(v)
    return v == 2 or v == 4
end

local function inBounds(r, c)
    return r >= 1 and r <= 8 and c >= 1 and c <= 8
end

-- Get all captures available for a single piece at (r,c).
-- chain_kills: set of "r_c" already captured this chain (to avoid re-capturing).
-- style: "french" (flying kings, all-dir man captures) or "english" (1-sq kings, fwd man captures)
-- Returns list of {fr, fc, tr, tc, kr, kc}
local function getCapturesForPiece(board, r, c, v, chain_kills, style)
    chain_kills = chain_kills or {}
    local captures = {}
    local dirs = { {-1,-1}, {-1,1}, {1,-1}, {1,1} }
    local french = (style ~= "english")

    if isKing(v) then
        if french then
            -- French flying queen: scan all 4 diagonals for an enemy, land anywhere beyond
            for _, d in ipairs(dirs) do
                local dr, dc = d[1], d[2]
                local nr, nc = r + dr, c + dc
                while inBounds(nr, nc) and board[nr][nc] == 0 do
                    nr = nr + dr; nc = nc + dc
                end
                if inBounds(nr, nc) then
                    local target = board[nr][nc]
                    local kill_key = nr .. "_" .. nc
                    local enemy = (isWhite(v) and isBlack(target)) or (isBlack(v) and isWhite(target))
                    if enemy and not chain_kills[kill_key] then
                        local lr, lc = nr + dr, nc + dc
                        while inBounds(lr, lc) and board[lr][lc] == 0 do
                            captures[#captures + 1] = { fr=r,fc=c,tr=lr,tc=lc,kr=nr,kc=nc }
                            lr = lr + dr; lc = lc + dc
                        end
                    end
                end
            end
        else
            -- English king: jump exactly 2 squares in all 4 diagonal directions
            for _, d in ipairs(dirs) do
                local kr, kc = r + d[1], c + d[2]
                local tr, tc = r + 2*d[1], c + 2*d[2]
                if inBounds(kr, kc) and inBounds(tr, tc) then
                    local target = board[kr][kc]
                    local kill_key = kr .. "_" .. kc
                    local enemy = (isWhite(v) and isBlack(target)) or (isBlack(v) and isWhite(target))
                    if enemy and not chain_kills[kill_key] and board[tr][tc] == 0 then
                        captures[#captures + 1] = { fr=r,fc=c,tr=tr,tc=tc,kr=kr,kc=kc }
                    end
                end
            end
        end
    else
        -- Man captures
        local cap_dirs
        if french then
            cap_dirs = dirs  -- French: all 4 diagonal directions
        else
            -- English: forward only (white moves up r-1, black moves down r+1)
            local fwd = isWhite(v) and -1 or 1
            cap_dirs = { {fwd, -1}, {fwd, 1} }
        end
        for _, d in ipairs(cap_dirs) do
            local kr, kc = r + d[1], c + d[2]
            local tr, tc = r + 2*d[1], c + 2*d[2]
            if inBounds(kr, kc) and inBounds(tr, tc) then
                local target = board[kr][kc]
                local kill_key = kr .. "_" .. kc
                local enemy = (isWhite(v) and isBlack(target)) or (isBlack(v) and isWhite(target))
                if enemy and not chain_kills[kill_key] and board[tr][tc] == 0 then
                    captures[#captures + 1] = { fr=r,fc=c,tr=tr,tc=tc,kr=kr,kc=kc }
                end
            end
        end
    end
    return captures
end

-- Get all simple (non-capture) moves for a single piece at (r,c).
local function getSimpleMovesForPiece(board, r, c, v, style)
    local moves = {}
    local dirs = { {-1,-1}, {-1,1}, {1,-1}, {1,1} }
    local french = (style ~= "english")

    if isKing(v) then
        for _, d in ipairs(dirs) do
            local dr, dc = d[1], d[2]
            if french then
                -- Flying queen: slide along diagonal
                local nr, nc = r + dr, c + dc
                while inBounds(nr, nc) and board[nr][nc] == 0 do
                    moves[#moves + 1] = { fr=r,fc=c,tr=nr,tc=nc,kr=nil,kc=nil }
                    nr = nr + dr; nc = nc + dc
                end
            else
                -- English king: single step only
                local nr, nc = r + dr, c + dc
                if inBounds(nr, nc) and board[nr][nc] == 0 then
                    moves[#moves + 1] = { fr=r,fc=c,tr=nr,tc=nc,kr=nil,kc=nil }
                end
            end
        end
    else
        -- Man: forward one square only (same for both styles)
        local fwd = isWhite(v) and -1 or 1
        for dc = -1, 1, 2 do
            local nr, nc = r + fwd, c + dc
            if inBounds(nr, nc) and board[nr][nc] == 0 then
                moves[#moves + 1] = { fr=r,fc=c,tr=nr,tc=nc,kr=nil,kc=nil }
            end
        end
    end
    return moves
end

-- Get all legal moves for the given turn (mandatory capture rule applied).
-- If chain != nil, only returns captures from the chain piece.
function CheckersBoard:_getAllMoves(turn, chain_pos, chain_kills)
    turn        = turn       or self.turn
    chain_pos   = chain_pos  or self.chain
    chain_kills = chain_kills or self.chain_kills

    local captures = {}
    local simples  = {}

    local style = self.style
    if chain_pos then
        -- Only the chain piece may move, and only captures
        local r, c = chain_pos[1], chain_pos[2]
        local v = self.board[r][c]
        if v ~= 0 then
            local caps = getCapturesForPiece(self.board, r, c, v, chain_kills, style)
            for _, m in ipairs(caps) do captures[#captures + 1] = m end
        end
        return captures  -- chain: captures only, no simples
    end

    for r = 1, 8 do
        for c = 1, 8 do
            local v = self.board[r][c]
            if v ~= 0 then
                local mine = (turn == "white" and isWhite(v)) or (turn == "black" and isBlack(v))
                if mine then
                    local caps = getCapturesForPiece(self.board, r, c, v, {}, style)
                    for _, m in ipairs(caps) do captures[#captures + 1] = m end
                end
            end
        end
    end

    if #captures > 0 then
        return captures  -- mandatory capture
    end

    for r = 1, 8 do
        for c = 1, 8 do
            local v = self.board[r][c]
            if v ~= 0 then
                local mine = (turn == "white" and isWhite(v)) or (turn == "black" and isBlack(v))
                if mine then
                    local sims = getSimpleMovesForPiece(self.board, r, c, v, style)
                    for _, m in ipairs(sims) do simples[#simples + 1] = m end
                end
            end
        end
    end
    return simples
end

function CheckersBoard:updateMoves()
    self._moves = self:_getAllMoves()
end

-- ---------------------------------------------------------------------------
-- Public: get moves for a specific piece (used by widget for highlighting)
-- ---------------------------------------------------------------------------

function CheckersBoard:getMovesForPiece(r, c)
    local result = {}
    for _, m in ipairs(self._moves) do
        if m.fr == r and m.fc == c then
            result[#result + 1] = m
        end
    end
    return result
end

-- ---------------------------------------------------------------------------
-- Apply a move directly (internal, no undo push)
-- Returns "win", "chain", or "ok"
-- ---------------------------------------------------------------------------

function CheckersBoard:_applyMoveDirectly(move)
    local fr, fc = move.fr, move.fc
    local tr, tc = move.tr, move.tc
    local kr, kc = move.kr, move.kc

    local v = self.board[fr][fc]
    self.board[fr][fc] = 0
    self.board[tr][tc] = v

    -- Remove captured piece (mark as killed, not yet removed for chain purposes)
    if kr then
        self.chain_kills[kr .. "_" .. kc] = { r = kr, c = kc, v = self.board[kr][kc] }
        self.board[kr][kc] = 0
    end

    -- Promotion
    local promoted = false
    if v == self.W_MAN and tr == 1 then
        self.board[tr][tc] = self.W_KING
        promoted = true
    elseif v == self.B_MAN and tr == 8 then
        self.board[tr][tc] = self.B_KING
        promoted = true
    end

    -- Check for chain capture (only if capture and not just promoted)
    if kr and not promoted then
        local new_v = self.board[tr][tc]
        local chain_caps = getCapturesForPiece(self.board, tr, tc, new_v, self.chain_kills, self.style)
        if #chain_caps > 0 then
            self.chain = { tr, tc }
            self._moves = chain_caps
            return "chain"
        end
    end

    -- End of move: switch turn
    self.chain      = nil
    self.chain_kills = {}
    self.turn = (self.turn == "white") and "black" or "white"
    self:updateMoves()

    -- Check win
    if #self._moves == 0 then
        self.won = (self.turn == "white") and "black" or "white"
        return "win"
    end

    return "ok"
end

-- ---------------------------------------------------------------------------
-- tapCell — public interaction point
-- Returns: "select", "move", "capture", "chain", "win", "invalid"
-- ---------------------------------------------------------------------------

function CheckersBoard:tapCell(r, c)
    if self.won then return "invalid" end

    local v = self.board[r][c]

    -- Mid-chain: only the chain piece can be moved
    if self.chain then
        local cr, cc = self.chain[1], self.chain[2]
        if r == cr and c == cc then
            -- Re-tapping chain piece: deselect not allowed mid-chain
            return "invalid"
        end
        -- Must be a valid landing square for the chain piece
        for _, m in ipairs(self._moves) do
            if m.tr == r and m.tc == c then
                -- Push undo snapshot before applying
                self:_pushUndo()
                local result = self:_applyMoveDirectly(m)
                self.selected = nil
                -- Map "ok" (chain ended) to "capture" for screen handling
                if result == "ok" then return "capture" end
                return result  -- "chain" or "win"
            end
        end
        return "invalid"
    end

    -- Check if tapping a destination square for currently selected piece
    if self.selected then
        local sr, sc = self.selected[1], self.selected[2]
        for _, m in ipairs(self._moves) do
            if m.fr == sr and m.fc == sc and m.tr == r and m.tc == c then
                self:_pushUndo()
                local result = self:_applyMoveDirectly(m)
                self.selected = nil
                if result == "chain" then
                    return "chain"
                elseif result == "win" then
                    return "win"
                elseif m.kr then
                    return "capture"
                else
                    return "move"
                end
            end
        end
        -- Tapping same piece: deselect
        if r == sr and c == sc then
            self.selected = nil
            return "select"
        end
    end

    -- Try to select a piece
    if v ~= 0 then
        local mine = (self.turn == "white" and isWhite(v)) or (self.turn == "black" and isBlack(v))
        if mine then
            local piece_moves = self:getMovesForPiece(r, c)
            if #piece_moves > 0 then
                self.selected = { r, c }
                return "select"
            end
        end
    end

    return "invalid"
end

-- ---------------------------------------------------------------------------
-- Undo
-- ---------------------------------------------------------------------------

function CheckersBoard:_pushUndo()
    -- Deep copy of board state for undo
    local snap = {
        turn        = self.turn,
        selected    = self.selected and { self.selected[1], self.selected[2] } or nil,
        won         = self.won,
        chain       = self.chain and { self.chain[1], self.chain[2] } or nil,
        chain_kills = {},
        board       = {},
    }
    for k, v in pairs(self.chain_kills) do
        snap.chain_kills[k] = { r = v.r, c = v.c, v = v.v }
    end
    for r = 1, 8 do
        snap.board[r] = {}
        for c = 1, 8 do
            snap.board[r][c] = self.board[r][c]
        end
    end
    self._undo:push(snap)
end

function CheckersBoard:undoMove()
    local snap = self._undo:pop()
    if not snap then return false end
    self.turn   = snap.turn
    self.selected = snap.selected
    self.won    = snap.won
    self.chain  = snap.chain
    self.chain_kills = snap.chain_kills
    for r = 1, 8 do
        for c = 1, 8 do
            self.board[r][c] = snap.board[r][c]
        end
    end
    self:updateMoves()
    return true
end

-- ---------------------------------------------------------------------------
-- Count pieces
-- ---------------------------------------------------------------------------

function CheckersBoard:countPieces()
    local w, b = 0, 0
    for r = 1, 8 do
        for c = 1, 8 do
            local v = self.board[r][c]
            if isWhite(v) then w = w + 1
            elseif isBlack(v) then b = b + 1 end
        end
    end
    return w, b
end

-- ---------------------------------------------------------------------------
-- Serialize / Load
-- ---------------------------------------------------------------------------

function CheckersBoard:serialize()
    local board_copy = {}
    for r = 1, 8 do
        board_copy[r] = {}
        for c = 1, 8 do
            board_copy[r][c] = self.board[r][c]
        end
    end
    local undo_data = self._undo:serialize()
    return {
        board       = board_copy,
        turn        = self.turn,
        won         = self.won,
        chain       = self.chain and { self.chain[1], self.chain[2] } or nil,
        chain_kills = self.chain_kills,
        style       = self.style,
        undo        = undo_data,
    }
end

function CheckersBoard:load(data)
    if type(data) ~= "table" or type(data.board) ~= "table" then
        return false
    end
    for r = 1, 8 do
        if type(data.board[r]) ~= "table" then return false end
        for c = 1, 8 do
            local v = data.board[r][c]
            if type(v) ~= "number" or v < 0 or v > 4 then return false end
            self.board[r][c] = v
        end
    end
    self.turn        = (data.turn == "black") and "black" or "white"
    self.won         = data.won
    self.selected    = nil
    self.chain       = data.chain and { data.chain[1], data.chain[2] } or nil
    self.chain_kills = type(data.chain_kills) == "table" and data.chain_kills or {}
    self.style       = (data.style == "english") and "english" or "french"
    if data.undo then self._undo:load(data.undo) end
    self:updateMoves()
    return true
end

-- ---------------------------------------------------------------------------
-- AI — minimax with alpha-beta pruning
-- ---------------------------------------------------------------------------

-- Static evaluation (from white's perspective)
local function evaluate(board_tbl)
    local score = 0
    for r = 1, 8 do
        for c = 1, 8 do
            local v = board_tbl[r][c]
            if v == 1 then      -- W_MAN
                score = score + 100 + (8 - r) * 5
            elseif v == 2 then  -- W_KING
                score = score + 300
            elseif v == 3 then  -- B_MAN
                score = score - 100 - (r - 1) * 5
            elseif v == 4 then  -- B_KING
                score = score - 300
            end
        end
    end
    return score
end

-- Make a temporary copy of board for AI simulation
local function copyBoard(src)
    local dst = {}
    for r = 1, 8 do
        dst[r] = {}
        for c = 1, 8 do
            dst[r][c] = src[r][c]
        end
    end
    return dst
end

-- Apply a move to a board copy, returning the new board and whether a chain exists.
-- Returns: new_board, is_chain, chain_pos, chain_kills, new_turn
local function applyMoveToBoard(board_tbl, move, turn, chain_kills_in, style)
    local nb = copyBoard(board_tbl)
    chain_kills_in = chain_kills_in or {}
    local new_chain_kills = {}
    for k, v in pairs(chain_kills_in) do new_chain_kills[k] = v end

    local fr, fc = move.fr, move.fc
    local tr, tc = move.tr, move.tc
    local kr, kc = move.kr, move.kc

    local v = nb[fr][fc]
    nb[fr][fc] = 0
    nb[tr][tc] = v

    local promoted = false
    if kr then
        new_chain_kills[kr .. "_" .. kc] = true
        nb[kr][kc] = 0
    end

    -- Promotion
    if v == 1 and tr == 1 then
        nb[tr][tc] = 2
        promoted = true
    elseif v == 3 and tr == 8 then
        nb[tr][tc] = 4
        promoted = true
    end

    -- Check chain
    if kr and not promoted then
        local new_v = nb[tr][tc]
        local chain_caps = getCapturesForPiece(nb, tr, tc, new_v, new_chain_kills, style)
        if #chain_caps > 0 then
            return nb, true, { tr, tc }, new_chain_kills, turn
        end
    end

    local new_turn = (turn == "white") and "black" or "white"
    return nb, false, nil, {}, new_turn
end

-- Get all moves for AI simulation (same mandatory-capture logic)
local function getAIMovesForState(board_tbl, turn, chain_pos, chain_kills, style)
    chain_kills = chain_kills or {}

    if chain_pos then
        local r, c = chain_pos[1], chain_pos[2]
        local v = board_tbl[r][c]
        if v == 0 then return {} end
        return getCapturesForPiece(board_tbl, r, c, v, chain_kills, style)
    end

    local captures = {}
    local simples  = {}
    for r = 1, 8 do
        for c = 1, 8 do
            local v = board_tbl[r][c]
            if v ~= 0 then
                local mine = (turn == "white" and isWhite(v)) or (turn == "black" and isBlack(v))
                if mine then
                    local caps = getCapturesForPiece(board_tbl, r, c, v, {}, style)
                    for _, m in ipairs(caps) do captures[#captures + 1] = m end
                end
            end
        end
    end
    if #captures > 0 then return captures end

    for r = 1, 8 do
        for c = 1, 8 do
            local v = board_tbl[r][c]
            if v ~= 0 then
                local mine = (turn == "white" and isWhite(v)) or (turn == "black" and isBlack(v))
                if mine then
                    local sims = getSimpleMovesForPiece(board_tbl, r, c, v, style)
                    for _, m in ipairs(sims) do simples[#simples + 1] = m end
                end
            end
        end
    end
    return simples
end

local function minimax(board_tbl, turn, depth, alpha, beta, chain_pos, chain_kills, style)
    local moves = getAIMovesForState(board_tbl, turn, chain_pos, chain_kills, style)

    if #moves == 0 then
        -- Current side has no moves — loses
        if turn == "white" then return -INF end
        return INF
    end

    if depth == 0 then
        return evaluate(board_tbl)
    end

    if turn == "white" then
        local best = -INF
        for _, m in ipairs(moves) do
            local nb, is_chain, new_chain, new_kills, new_turn =
                applyMoveToBoard(board_tbl, m, turn, chain_kills, style)
            local val
            if is_chain then
                val = minimax(nb, new_turn, depth, alpha, beta, new_chain, new_kills, style)
            else
                val = minimax(nb, new_turn, depth - 1, alpha, beta, nil, nil, style)
            end
            if val > best then best = val end
            if best > alpha then alpha = best end
            if alpha >= beta then break end
        end
        return best
    else
        local best = INF
        for _, m in ipairs(moves) do
            local nb, is_chain, new_chain, new_kills, new_turn =
                applyMoveToBoard(board_tbl, m, turn, chain_kills, style)
            local val
            if is_chain then
                val = minimax(nb, new_turn, depth, alpha, beta, new_chain, new_kills, style)
            else
                val = minimax(nb, new_turn, depth - 1, alpha, beta, nil, nil, style)
            end
            if val < best then best = val end
            if best < beta then beta = best end
            if alpha >= beta then break end
        end
        return best
    end
end

function CheckersBoard:getAIMove(depth)
    depth = depth or 4
    local moves = self._moves
    if #moves == 0 then return nil end

    local best_move = nil
    local is_white  = (self.turn == "white")
    local best_val  = is_white and -INF or INF

    local style = self.style
    for _, m in ipairs(moves) do
        local nb, is_chain, new_chain, new_kills, new_turn =
            applyMoveToBoard(self.board, m, self.turn, self.chain_kills, style)
        local val
        if is_chain then
            val = minimax(nb, new_turn, depth, -INF, INF, new_chain, new_kills, style)
        else
            val = minimax(nb, new_turn, depth - 1, -INF, INF, nil, nil, style)
        end
        if is_white then
            if val > best_val then
                best_val  = val
                best_move = m
            end
        else
            if val < best_val then
                best_val  = val
                best_move = m
            end
        end
    end
    return best_move
end

-- ---------------------------------------------------------------------------
-- applyAIMove — apply best AI move including chain handling
-- Returns "ok", "win", or "none"
-- ---------------------------------------------------------------------------

function CheckersBoard:applyAIMove(depth)
    local move = self:getAIMove(depth)
    if not move then return "none" end

    self:_pushUndo()
    local result = self:_applyMoveDirectly(move)

    -- Handle chains greedily
    local safety = 0
    while self.chain and safety < 20 do
        safety = safety + 1
        local more = self:getMovesForPiece(self.chain[1], self.chain[2])
        if #more == 0 then
            self.chain      = nil
            self.chain_kills = {}
            self.turn = (self.turn == "white") and "black" or "white"
            self:updateMoves()
            break
        end
        result = self:_applyMoveDirectly(more[1])
        if result == "win" then break end
    end

    if self.won then return "win" end
    return "ok"
end

return CheckersBoard
