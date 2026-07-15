local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local ButtonTable     = require("ui/widget/buttontable")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("i18n")

local MenuHelper  = require("menu_helper")
local ScreenBase  = require("screen_base")

local CheckersBoard       = lrequire("board")
local CheckersBoardWidget = lrequire("board_widget")

local DeviceScreen = Device.screen

-- Difficulty → minimax depth
local DIFF_DEPTH = { easy = 2, medium = 4, hard = 6 }

-- ---------------------------------------------------------------------------
-- DamesScreen
-- ---------------------------------------------------------------------------

local GAME_RULES_EN = _([[
Draughts (Checkers) — Rules

Two players take turns moving pieces diagonally on the dark squares.

Movement:
• Ordinary pieces move diagonally forward one square.
• Captures: jump diagonally over an opponent's piece to an empty square behind it. The captured piece is removed.
• Multiple jumps in one turn are mandatory if available.

Kings:
• A piece that reaches the far row becomes a King.
• Kings can move and capture diagonally in both directions.

Win by capturing all opponent pieces, or by leaving them unable to move.
]])

local GAME_RULES_FR = [[
Jeu de Dames — Règles

Deux joueurs déplacent leurs pions en diagonale sur les cases sombres.

Déplacements :
• Les pions ordinaires se déplacent d'une case en diagonale vers l'avant.
• Prise : sautez en diagonale par-dessus un pion adverse vers une case vide derrière lui. Le pion capturé est retiré.
• Les prises multiples en un seul tour sont obligatoires si disponibles.

Dames :
• Un pion atteignant la rangée du fond devient une Dame.
• Les Dames peuvent se déplacer et capturer en diagonale dans les deux directions.

Gagnez en capturant tous les pions adverses, ou en les laissant sans mouvement possible.
]]

local DamesScreen = ScreenBase:extend{}

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function DamesScreen:init()
    local state  = self.plugin:loadState()
    local style  = self.plugin:getSetting("style", "french")
    self.board   = CheckersBoard:new{ style = style }
    if not self.board:load(state) then
        self.board:generate()
    end
    ScreenBase.init(self)  -- calls buildLayout()
end

function DamesScreen:serializeState()
    return self.board:serialize()
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

function DamesScreen:buildLayout()
    local board = self.board

    self.board_widget = CheckersBoardWidget:new{
        board        = board,
        onCellAction = function(r, c) self:onCellAction(r, c) end,
    }

    local is_landscape = self:isLandscape()
    local sw = DeviceScreen:getWidth()
    local sh = DeviceScreen:getHeight()

    local board_frame = FrameContainer:new{
        padding = Size.padding.default,
        margin  = Size.margin.default,
        self.board_widget,
    }

    local board_frame_size = self.board_widget.size
        + (Size.padding.default + Size.margin.default) * 2

    local button_width
    if is_landscape then
        local right_w = sw - board_frame_size - Size.span.horizontal_default * 2
        button_width  = math.max(right_w - Size.span.horizontal_default, 100)
    else
        button_width = math.floor(sw * 0.92)
    end

    -- Title bar with Options menu
    local title_bar = self:buildTitleBar(_("Dames"), function()
        return {
            { text = _("Nouveau"),                 callback = function() self:onNewGame() end },
            { text = self:getPlayersButtonText(),  callback = function() self:openPlayersMenu() end },
            { text = self:getDiffButtonText(),     callback = function() self:openDifficultyMenu() end },
            { text = self:getStyleButtonText(),    callback = function() self:openStyleMenu() end },
            self:makeRulesButtonConfig(GAME_RULES_EN, GAME_RULES_FR),
        }
    end)

    -- Bottom button row: Undo
    local bottom_buttons = ButtonTable:new{
        width                 = button_width,
        shrink_unneeded_width = true,
        buttons = {{
            { text = _("Annuler"), callback = function() self:onUndo() end },
        }},
    }

    if is_landscape then
        local right_panel = VerticalGroup:new{
            align = "center",
            self.status_text,
            VerticalSpan:new{ width = Size.span.vertical_large },
            bottom_buttons,
        }
        local content = HorizontalGroup:new{
            align = "center",
            board_frame,
            HorizontalSpan:new{ width = Size.span.horizontal_default },
            right_panel,
        }
        self:buildLandscapeLayout(title_bar, content)
    else
        local content = VerticalGroup:new{
            align = "center",
            board_frame,
            VerticalSpan:new{ width = Size.span.vertical_large },
            self.status_text,
        }
        self:buildPortraitLayout(title_bar, content, bottom_buttons)
    end
    self:updateStatus()
end

-- ---------------------------------------------------------------------------
-- Cell interaction
-- ---------------------------------------------------------------------------

function DamesScreen:onCellAction(r, c)
    local board   = self.board
    local result  = board:tapCell(r, c)

    if result == "select" then
        self.board_widget:refresh()
        self:updateStatus()

    elseif result == "move" or result == "capture" then
        self.board_widget:refresh()
        self.plugin:saveState(board:serialize())
        self:updateStatus()
        self:maybeDoAI()

    elseif result == "chain" then
        self.board_widget:refresh()
        self:updateStatus(_("Continuez la prise !"))

    elseif result == "win" then
        self.board_widget:refresh()
        self.plugin:saveState(board:serialize())
        self:updateStatus()

    -- "invalid": do nothing
    end
end

-- ---------------------------------------------------------------------------
-- AI
-- ---------------------------------------------------------------------------

function DamesScreen:maybeDoAI()
    if self.board.won then return end
    local players = self.plugin:getSetting("players", 1)
    if players ~= 1 then return end
    local ai_color = self.plugin:getSetting("ai_color", "black")
    if self.board.turn ~= ai_color then return end

    self:updateStatus(_("L'IA reflechit..."))
    UIManager:scheduleIn(0.05, function()
        self:_doAIMove()
    end)
end

function DamesScreen:_doAIMove()
    local board = self.board
    if board.won then return end

    local diff  = self.plugin:getSetting("difficulty", "medium")
    local depth = DIFF_DEPTH[diff] or 4

    local ai_result = board:applyAIMove(depth)
    self.board_widget:refresh()
    self.plugin:saveState(board:serialize())

    if ai_result == "win" then
        self:updateStatus()
    else
        self:updateStatus()
    end
end

-- ---------------------------------------------------------------------------
-- New game
-- ---------------------------------------------------------------------------

function DamesScreen:onNewGame()
    local style = self.plugin:getSetting("style", "french")
    self.board = CheckersBoard:new{ style = style }
    self.board:generate()
    self.plugin:saveState(self.board:serialize())
    self:buildLayout()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    UIManager:scheduleIn(0.1, function() self:maybeDoAI() end)
end

-- ---------------------------------------------------------------------------
-- Undo
-- ---------------------------------------------------------------------------

function DamesScreen:onUndo()
    if self.board:undoMove() then
        self.plugin:saveState(self.board:serialize())
        self.board_widget:refresh()
        self:updateStatus()
    else
        self:showMessage(_("Rien a annuler."), 2)
    end
end

-- ---------------------------------------------------------------------------
-- Status
-- ---------------------------------------------------------------------------

function DamesScreen:updateStatus(msg)
    local status
    if msg then
        status = msg
    elseif self.board.won then
        local winner = (self.board.won == "white") and _("Blancs") or _("Noirs")
        status = winner .. " " .. _("ont gagne !")
    else
        local w, b    = self.board:countPieces()
        local turn    = (self.board.turn == "white") and _("Blancs") or _("Noirs")
        local players = self.plugin:getSetting("players", 1)
        local diff    = self.plugin:getSetting("difficulty", "medium")
        local dlabel  = MenuHelper.DIFFICULTY_LABELS[diff] or diff
        if players == 1 then
            local ai_col   = self.plugin:getSetting("ai_color", "black")
            local ai_label = (ai_col == "black") and _("(IA=Noirs)") or _("(IA=Blancs)")
            status = string.format("%s joue  Blancs: %d  Noirs: %d  %s %s",
                turn, w, b, dlabel, ai_label)
        else
            status = string.format("%s joue  Blancs: %d  Noirs: %d",
                turn, w, b)
        end
    end
    ScreenBase.updateStatus(self, status)
end

-- ---------------------------------------------------------------------------
-- Button labels
-- ---------------------------------------------------------------------------

function DamesScreen:getStyleButtonText()
    local style = self.plugin:getSetting("style", "french")
    return style == "english" and _("Anglaises") or _("Françaises")
end

function DamesScreen:getPlayersButtonText()
    local players = self.plugin:getSetting("players", 1)
    return players == 1 and _("1 joueur") or _("2 joueurs")
end

function DamesScreen:getDiffButtonText()
    local diff   = self.plugin:getSetting("difficulty", "medium")
    local dlabel = MenuHelper.DIFFICULTY_LABELS[diff] or diff
    return dlabel
end

-- ---------------------------------------------------------------------------
-- Menus
-- ---------------------------------------------------------------------------

function DamesScreen:openPlayersMenu()
    MenuHelper.openPickerMenu{
        title      = _("Mode de jeu"),
        items      = {
            { id = 1, text = _("1 joueur (contre IA)") },
            { id = 2, text = _("2 joueurs") },
        },
        current_id = self.plugin:getSetting("players", 1),
        on_select  = function(id)
            self.plugin:saveSetting("players", id)
            -- Update button text
            local btn = self.top_buttons and self.top_buttons:getButtonById("players_btn")
            if btn then
                btn:setText(self:getPlayersButtonText(), btn.width)
            end
            self:updateStatus()
        end,
        parent = self,
    }
end

function DamesScreen:openStyleMenu()
    local STYLE_LABELS = { french = _("Françaises (dames volantes)"), english = _("Anglaises (dames classiques)") }
    MenuHelper.openPickerMenu{
        title      = _("Règles du jeu"),
        items      = {
            { id = "french",  text = STYLE_LABELS.french },
            { id = "english", text = STYLE_LABELS.english },
        },
        current_id = self.plugin:getSetting("style", "french"),
        on_select  = function(id)
            self.plugin:saveSetting("style", id)
            local btn = self.top_buttons and self.top_buttons:getButtonById("style_btn")
            if btn then
                btn:setText(self:getStyleButtonText(), btn.width)
            end
            -- Start a new game with the new ruleset
            local style = id
            self.board = CheckersBoard:new{ style = style }
            self.board:generate()
            self.plugin:saveState(self.board:serialize())
            self:buildLayout()
            UIManager:setDirty(self, function() return "ui", self.dimen end)
            UIManager:scheduleIn(0.1, function() self:maybeDoAI() end)
        end,
        parent = self,
    }
end

function DamesScreen:openDifficultyMenu()
    MenuHelper.openDifficultyMenu{
        current   = self.plugin:getSetting("difficulty", "medium"),
        on_select = function(id)
            self.plugin:saveSetting("difficulty", id)
            local btn = self.top_buttons and self.top_buttons:getButtonById("diff_btn")
            if btn then
                btn:setText(self:getDiffButtonText(), btn.width)
            end
            self:updateStatus()
        end,
        parent = self,
    }
end

return DamesScreen
