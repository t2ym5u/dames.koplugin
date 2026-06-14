local Blitbuffer = require("ffi/blitbuffer")
local Font       = require("ui/font")
local Geom       = require("ui/geometry")
local RenderText = require("ui/rendertext")
local UIManager  = require("ui/uimanager")

local gwb            = require("grid_widget_base")
local GridWidgetBase = gwb.GridWidgetBase
local drawLine       = gwb.drawLine

local C_LIGHT_SQ = Blitbuffer.COLOR_WHITE
local C_DARK_SQ  = Blitbuffer.COLOR_GRAY_4
local C_SEL      = Blitbuffer.COLOR_GRAY_D  -- selected highlight
local C_DOT      = Blitbuffer.COLOR_GRAY_9  -- valid move dot on dark sq
local C_LINE     = Blitbuffer.COLOR_BLACK

-- ---------------------------------------------------------------------------
-- CheckersBoardWidget
-- ---------------------------------------------------------------------------

local CheckersBoardWidget = GridWidgetBase:extend{
    board        = nil,
    size_ratio   = 0.80,
    onCellAction = nil,
}

function CheckersBoardWidget:init()
    self.cols = 8
    self.rows = 8
    GridWidgetBase.init(self)
end

function CheckersBoardWidget:onCellTap(row, col)
    if self.onCellAction then self.onCellAction(row, col) end
end

function CheckersBoardWidget:paintTo(bb, x, y)
    -- Save paint_rect for gesture hit-testing
    self.paint_rect = Geom:new{ x = x, y = y, w = self.dimen.w, h = self.dimen.h }

    local board = self.board
    local n     = 8
    local cw    = self.cell_w
    local ch    = self.cell_h
    -- Hoist constant cell pixel dimensions out of all loops
    local cew   = self.cell_w_px
    local ceh   = self.cell_h_px
    local pad   = math.max(3, math.floor(math.min(cew, ceh) * 0.12))
    local pw    = cew - 2 * pad
    local ph    = ceh - 2 * pad
    local bw    = math.max(1, math.floor(math.min(cew, ceh) * 0.05))
    local dot   = math.max(3, math.floor(math.min(cw, ch) * 0.15))
    local dot_h = math.floor(dot / 2)
    local cw_h  = math.floor(cw / 2)
    local ch_h  = math.floor(ch / 2)

    -- Background squares
    for r = 1, n do
        for c = 1, n do
            local cx   = x + math.floor((c - 1) * cw)
            local cy   = y + math.floor((r - 1) * ch)
            local dark = (r + c) % 2 == 1
            bb:paintRect(cx, cy, cew, ceh, dark and C_DARK_SQ or C_LIGHT_SQ)
        end
    end

    -- Selected highlight
    if board.selected then
        local sr = board.selected[1]
        local sc = board.selected[2]
        local sx = x + math.floor((sc - 1) * cw)
        local sy = y + math.floor((sr - 1) * ch)
        bb:paintRect(sx, sy, cew, ceh, C_SEL)
    end

    -- Valid move dots for selected or chain piece
    local move_targets = {}
    local ref_r, ref_c
    if board.chain then
        ref_r, ref_c = board.chain[1], board.chain[2]
    elseif board.selected then
        ref_r, ref_c = board.selected[1], board.selected[2]
    end
    if ref_r then
        for _, m in ipairs(board:getMovesForPiece(ref_r, ref_c)) do
            move_targets[m.tr * 100 + m.tc] = true
        end
    end

    -- Piece constants
    local W_MAN  = board.W_MAN
    local W_KING = board.W_KING
    local B_MAN  = board.B_MAN
    local B_KING = board.B_KING

    local face = self.number_face

    -- Draw pieces
    for r = 1, n do
        for c = 1, n do
            local v = board.board[r][c]
            if v ~= 0 then
                local cx = x + math.floor((c - 1) * cw)
                local cy = y + math.floor((r - 1) * ch)

                local fill, border, letter_color, letter
                if v == W_MAN then
                    fill         = Blitbuffer.COLOR_WHITE
                    border       = Blitbuffer.COLOR_BLACK
                    letter_color = Blitbuffer.COLOR_BLACK
                    letter       = nil
                elseif v == W_KING then
                    fill         = Blitbuffer.COLOR_WHITE
                    border       = Blitbuffer.COLOR_BLACK
                    letter_color = Blitbuffer.COLOR_BLACK
                    letter       = "D"
                elseif v == B_MAN then
                    fill         = Blitbuffer.COLOR_BLACK
                    border       = Blitbuffer.COLOR_GRAY_4
                    letter_color = Blitbuffer.COLOR_WHITE
                    letter       = nil
                elseif v == B_KING then
                    fill         = Blitbuffer.COLOR_BLACK
                    border       = Blitbuffer.COLOR_GRAY_4
                    letter_color = Blitbuffer.COLOR_WHITE
                    letter       = "D"
                end

                if fill then
                    bb:paintRect(cx + pad, cy + pad, pw, ph, fill)
                    bb:paintRect(cx + pad,           cy + pad,           pw, bw, border)
                    bb:paintRect(cx + pad,           cy + pad + ph - bw, pw, bw, border)
                    bb:paintRect(cx + pad,           cy + pad,           bw, ph, border)
                    bb:paintRect(cx + pad + pw - bw, cy + pad,           bw, ph, border)

                    if letter and face then
                        local m  = RenderText:sizeUtf8Text(0, pw - 2, face, letter, true, false)
                        local tx = cx + math.floor((cew - m.x) / 2)
                        local ty = cy + math.floor((ceh - (m.y_bottom - m.y_top)) / 2) - m.y_top
                        RenderText:renderUtf8Text(bb, tx, ty, face, letter, true, false, letter_color)
                    end
                end
            end

            -- Valid move dot
            if move_targets[r * 100 + c] then
                local cx = x + math.floor((c - 1) * cw)
                local cy = y + math.floor((r - 1) * ch)
                bb:paintRect(cx + cw_h - dot_h, cy + ch_h - dot_h, dot, dot, C_DOT)
            end
        end
    end

    -- Grid lines
    local thin  = 1
    local thick = math.max(2, math.floor(math.min(cw, ch) * 0.08))
    for i = 0, n do
        local lw = (i == 0 or i == n) and thick or thin
        drawLine(bb, x + math.floor(i * cw), y, lw, self.dimen.h, C_LINE)
        drawLine(bb, x, y + math.floor(i * ch), self.dimen.w, lw, C_LINE)
    end
end

return CheckersBoardWidget
