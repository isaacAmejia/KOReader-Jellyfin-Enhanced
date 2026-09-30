--[[
Jellyfin UI components
@module koplugin.jellyfin.ui
]]

local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local util = require("util")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local ProgressbarDialog = require("ui/widget/progressbardialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local FFIUtil = require("ffi/util")
local logger = require("logger")
local _ = require("gettext")

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalGroup = require("ui/widget/verticalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalSpan = require("ui/widget/verticalspan")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local Size = require("ui/size")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")

local T = FFIUtil.template

local UI = {}

local function trim(value)
    if type(value) ~= "string" then return "" end
    return value:match("^%s*(.-)%s*$") or ""
end

local function sanitizeFilename(name, fallback)
    name = trim(name)
    if name == "" then
        name = fallback or "item"
    end

    -- Keep Unicode and normal punctuation, but remove characters that are
    -- unsafe or reserved on common filesystems.
    name = name:gsub("[%c/\\:*?\"<>|]", "_")
    name = name:gsub("%s+$", "")

    if name == "" or name == "." or name == ".." then
        name = fallback or "item"
    end

    return name
end

local AUDIO_EXTENSIONS = {
    mp3 = true,
    m4a = true,
    m4b = true,
    ogg = true,
    opus = true,
    flac = true,
    wav = true,
    aac = true,
    wma = true,
}

local function itemPath(book)
    local path = book and book.Path

    if (not path or path == "")
            and book
            and type(book.MediaSources) == "table"
            and book.MediaSources[1]
    then
        path = book.MediaSources[1].Path
    end

    return path
end

local function normalizeExtension(value)
    if type(value) ~= "string" then
        return nil
    end

    value = trim(value):lower()
    value = value:gsub("^%.", "")
    value = value:match("^([^,;]+)") or value

    if value:match("^[%w]+$")
            and #value > 0
            and #value <= 12
    then
        return "." .. value
    end

    return nil
end

local function itemExtension(book)
    local path = itemPath(book)
    local path_ext =
        path
        and path:match("%.([^./\\]+)$")
    local ext = normalizeExtension(path_ext)

    if ext then
        return ext
    end

    local media_source =
        book
        and type(book.MediaSources) == "table"
        and book.MediaSources[1]
        or nil

    ext = normalizeExtension(
        media_source and media_source.Container
    ) or normalizeExtension(
        book and book.Container
    )

    if ext then
        return ext
    end

    if book
            and (
                book.Type == "AudioBook"
                or book.Type == "Audio"
            )
    then
        return ".m4b"
    end

    -- Jellyfin Books are most commonly EPUBs. This final fallback is only
    -- used when the server supplied neither a path extension nor a container.
    return ".epub"
end

local function isAudiobook(book)
    if not book then return false end

    if book.Type == "AudioBook" or book.Type == "Audio" then
        return true
    end

    local ext = itemExtension(book):match("^%.(.+)$")
    return ext and AUDIO_EXTENSIONS[ext] or false
end

local COVER_CACHE_DIR = DataStorage:getDataDir() .. "/jellyfin_covers"
local COVER_CACHE_KEEP = 120
local COVER_CACHE_PRUNE_AT = 160
local BOOKS_PER_PAGE = 5
local BOOK_BATCH_SIZE = 40

local Screen = Device.screen

--[[
Book result item
]]

local BookResultItem = InputContainer:extend {
    book = nil,
    width = nil,
    height = nil,
    callback = nil,
}

function BookResultItem:init()
    self.width = self.width or Screen:getWidth()
    self.height = self.height or Screen:scaleBySize(95)

    self.dimen = Geom:new {
        x = 0,
        y = 0,
        w = self.width,
        h = self.height,
    }

    self[1] = FrameContainer:new {
        width = self.width,
        height = self.height,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 1,
        bordercolor = Blitbuffer.COLOR_GRAY_3,
        padding = Screen:scaleBySize(6),

        HorizontalGroup:new {
            align = "center",

            self:createCover(),

            HorizontalSpan:new {
                width = Screen:scaleBySize(12),
            },

            self:createBookText(),
        },
    }

    self.ges_events = {
        Tap = {
            GestureRange:new {
                ges = "tap",
                range = self.dimen,
            },
        },
    }
end

function BookResultItem:createCover()
    local cover_width = Screen:scaleBySize(55)
    local cover_height = Screen:scaleBySize(78)

    if self.book.cover_path and util.fileExists(self.book.cover_path) then
        return CenterContainer:new {
            dimen = {
                w = cover_width,
                h = cover_height,
            },

            ImageWidget:new {
                file = self.book.cover_path,
                width = cover_width,
                height = cover_height,
                scale_factor = 0,
            },
        }
    end

    return FrameContainer:new {
        width = cover_width,
        height = cover_height,
        background = Blitbuffer.COLOR_LIGHT_GRAY,
        bordersize = 1,
        bordercolor = Blitbuffer.COLOR_GRAY_3,

        CenterContainer:new {
            dimen = {
                w = cover_width,
                h = cover_height,
            },

            TextWidget:new {
                text = _("No Cover"),
                face = Font:getFace("smallinfofont"),
            },
        },
    }
end

function BookResultItem:getAuthor()
    if self.book.People then
        for _, person in ipairs(self.book.People) do
            if person.Type == "Author" and person.Name then
                return person.Name
            end
        end

        if self.book.People[1] and self.book.People[1].Name then
            return self.book.People[1].Name
        end
    end

    return _("Unknown Author")
end

function BookResultItem:createBookText()
    local text_width = self.width - Screen:scaleBySize(95)

    local title = self.book.Name or _("Untitled")
    local author = self:getAuthor()

    local read_status = ""

    if self.book.UserData and self.book.UserData.Played then
        read_status = " ✓"
    end

    local title_widget = TextBoxWidget:new {
        text = title .. read_status,
        width = text_width,
        height = Screen:scaleBySize(42),
        face = Font:getFace("tfont"),
        alignment = "left",
    }

    local author_widget = TextBoxWidget:new {
        text = author,
        width = text_width,
        height = Screen:scaleBySize(28),
        face = Font:getFace("smallinfofont"),
        alignment = "left",
    }

    return VerticalGroup:new {
        align = "left",

        title_widget,

        VerticalSpan:new {
            height = Screen:scaleBySize(3),
        },

        author_widget,
    }
end

function BookResultItem:onTap()
    if self.callback then
        self.callback(self.book)
    end

    return true
end

--[[
Book results view
]]

local BookResultsView = InputContainer:extend {
    ui_handler = nil,
    books = nil,
    library_id = nil,
    library_name = nil,
    search_term = nil,
    page = 1,
}

function BookResultsView:init()
    self.books = self.books or {}

    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()

    self.dimen = Geom:new {
        x = 0,
        y = 0,
        w = self.screen_w,
        h = self.screen_h,
    }

    self:build()
end

function BookResultsView:getPageCount()
    local total =
        self.total_count or #self.books

    if total <= 0 then
        return 1
    end

    local per_page =
        self.books_per_page or BOOKS_PER_PAGE

    return math.ceil(total / per_page)
end

function BookResultsView:getPageBooks()
    local per_page =
        self.books_per_page or BOOKS_PER_PAGE
    local start_index =
        ((self.page - 1) * per_page) + 1

    local end_index = math.min(
        start_index + per_page - 1,
        #self.books
    )

    local page_books = {}

    for i = start_index, end_index do
        table.insert(page_books, self.books[i])
    end

    return page_books
end

function BookResultsView:build()
    local title = self.library_name or _("Books")

    if self.search_term and self.search_term ~= "" then
        title = _("Search: ") .. self.search_term
    end

    self.titlebar = TitleBar:new {
        width = self.screen_w,
        align = "left",
        title = title,

        left_icon = "appbar.search",

        left_icon_tap_callback = function()
            self.ui_handler:searchBooks(
                self.library_id,
                self.library_name,
                self
            )
        end,

        close_callback = function()
            self.ui_handler.cover_job_id =
                (self.ui_handler.cover_job_id or 0) + 1
            UIManager:close(self)

            if self.ui_handler.results_view == self then
                self.ui_handler.results_view = nil
            end

            if self.ui_handler.current_libraries then
                self.ui_handler:showLibrariesMenu(
                    self.ui_handler.current_libraries
                )
            end
        end,

        show_parent = self,
    }

    local content_top = self.titlebar:getHeight()
    local footer_height = Screen:scaleBySize(55)

    local available_height =
        self.screen_h - content_top - footer_height
    local minimum_row_height =
        Screen:scaleBySize(75)

    self.books_per_page = math.max(
        1,
        math.min(
            BOOKS_PER_PAGE,
            math.floor(
                available_height
                / minimum_row_height
            )
        )
    )

    local row_height = math.floor(
        available_height
        / self.books_per_page
    )

    local rows = {}

    for _, book in ipairs(self:getPageBooks()) do
        table.insert(rows, BookResultItem:new {
            book = book,
            width = self.screen_w,
            height = row_height,

            callback = function(selected_book)
                self.ui_handler:showBookDetails(selected_book)
            end,
        })
    end

    while #rows < self.books_per_page do
        table.insert(rows, VerticalSpan:new {
            height = row_height,
        })
    end

    local results = VerticalGroup:new {
        align = "left",
        unpack(rows),
    }

    local previous_button = Button:new {
        icon = "chevron.left",
        bordersize = 0,

        callback = function()
            self:previousPage()
        end,
    }

    local next_button = Button:new {
        icon = "chevron.right",
        bordersize = 0,

        callback = function()
            self:nextPage()
        end,
    }

    if self.page <= 1 then
        previous_button:disable()
    end

    if self.page >= self:getPageCount() then
        next_button:disable()
    end

    local page_text = TextWidget:new {
        text = T(
            _("Page %1 / %2"),
            self.page,
            self:getPageCount()
        ),
        face = Font:getFace("smallinfofont"),
    }

    local footer = FrameContainer:new {
        width = self.screen_w,
        height = footer_height,

        background = Blitbuffer.COLOR_WHITE,
        bordersize = 1,
        bordercolor = Blitbuffer.COLOR_GRAY_3,

        CenterContainer:new {
            dimen = {
                w = self.screen_w,
                h = footer_height,
            },

            HorizontalGroup:new {
                align = "center",

                previous_button,

                HorizontalSpan:new {
                    width = Screen:scaleBySize(20),
                },

                page_text,

                HorizontalSpan:new {
                    width = Screen:scaleBySize(20),
                },

                next_button,
            },
        },
    }

    self[1] = FrameContainer:new {
        width = self.screen_w,
        height = self.screen_h,

        background = Blitbuffer.COLOR_WHITE,

        VerticalGroup:new {
            align = "left",

            self.titlebar,

            results,

            footer,
        },
    }
end

function BookResultsView:refresh()
    local old_root = self[1]

    self:build()

    -- Monochrome e-ink can use the cheaper UI waveform. Color e-ink needs
    -- KOReader's full refresh path to avoid degrading cover artwork.
    UIManager:setDirty(
        self,
        Screen:isColorEnabled()
            and "full"
            or "ui"
    )

    -- Page/search changes replace the complete widget subtree. Defer freeing
    -- the previous tree until the current input/paint cycle has completed so
    -- repeated browsing does not retain old cover/text widgets.
    if old_root
            and old_root ~= self[1]
            and type(old_root.free) == "function"
    then
        UIManager:nextTick(function()
            pcall(old_root.free, old_root)
            collectgarbage("step", 120)
        end)
    end
end

function BookResultsView:setBooks(
    books,
    search_term,
    total_count
)
    self.books = books or {}
    self.search_term = search_term
    self.total_count =
        total_count or #self.books
    self.loading_more = false
    self.page = 1

    self:refresh()
    self.ui_handler:queuePageCovers(self)
end

function BookResultsView:previousPage()
    if self.page <= 1 then
        return
    end

    self.page = self.page - 1
    self:refresh()
    self.ui_handler:queuePageCovers(self)
end

function BookResultsView:nextPage()
    if self.page >= self:getPageCount() then
        return
    end

    local target_page = self.page + 1
    local per_page =
        self.books_per_page or BOOKS_PER_PAGE
    local total_count =
        self.total_count or #self.books
    local target_last_index =
        math.min(
            target_page * per_page,
            total_count
        )

    if target_last_index > #self.books
            and #self.books < total_count
    then
        self.ui_handler:loadMoreBooks(
            self,
            target_page
        )
        return
    end

    self.page = target_page
    self:refresh()
    self.ui_handler:queuePageCovers(self)
end

--[[
UI object
]]

function UI:new(config, api)
    local o = {
        config = config,
        api = api,
        current_libraries = nil,
        current_books = nil,
        results_view = nil,
        cover_job_id = 0,
        detailed_book = nil,
        cover_cache_pruned = false,
    }

    setmetatable(o, self)
    self.__index = self

    return o
end

function UI:configureServer()
    local input_dialog

    input_dialog = InputDialog:new {
        title = _("Enter Jellyfin Server URL"),
        input = self.config:getServerUrl(),
        input_hint = "https://jellyfin.example.com",

        buttons = {
            {
                {
                    text = _("Cancel"),

                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },

                {
                    text = _("Save"),
                    is_enter_default = true,

                    callback = function()
                        local url = trim(input_dialog:getInputText())
                        url = url:gsub("/+$", "")

                        if url == "" then
                            UIManager:show(InfoMessage:new {
                                text = _("Enter your Jellyfin server URL."),
                            })
                            return
                        end

                        if not url:match("^https?://") then
                            UIManager:show(InfoMessage:new {
                                text = _(
                                    "Server URL must include http:// or https://"
                                ),
                            })
                            return
                        end

                        self.config:setServerUrl(url)

                        UIManager:show(InfoMessage:new {
                            text = _("Server URL saved"),
                        })

                        UIManager:close(input_dialog)
                    end,
                },
            },
        },
    }

    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function UI:handleApiError(error_code, default_msg)
    if error_code == 401 then
        logger.info(
            "Jellyfin: Encountered 401 Unauthorised, clearing auth."
        )

        self.config:clearAuth()

        UIManager:show(ConfirmBox:new {
            text = _(
                "Your session is invalid or has expired.\n\n"
                .. "Please log in again from the Jellyfin plugin's menu."
            ),
        })

    elseif error_code == "parse_error" then
        UIManager:show(InfoMessage:new {
            text = _("Failed to parse server response."),
        })

    elseif error_code then
        UIManager:show(InfoMessage:new {
            text = T(
                _("%1 (code %2)"),
                default_msg,
                error_code
            ),
        })

    else
        UIManager:show(InfoMessage:new {
            text = default_msg,
        })
    end
end

--[[
Library browsing
]]

function UI:browseBooks()
    NetworkMgr:runWhenOnline(function()
        self:getBookLibraries()
    end)
end

function UI:getBookLibraries()
    UIManager:show(InfoMessage:new {
        text = _("Loading libraries..."),
        timeout = 1,
    })

    if not self.config:isLoggedIn() then
        UIManager:show(InfoMessage:new {
            text = _("Not logged in. Please login first."),
        })

        return
    end

    local success, result = self.api:getUserViews()

    if success then
        local items = type(result) == "table"
            and type(result.Items) == "table"
            and result.Items
            or {}

        logger.info(
            "Jellyfin: Response has",
            #items,
            "total items"
        )

        local book_libraries = {}

        for _, item in ipairs(items) do
            logger.info(
                "Jellyfin: Found library:",
                item.Name,
                "Type:",
                item.CollectionType or "none"
            )

            if item.CollectionType == "books" then
                table.insert(book_libraries, item)
            end
        end

        logger.info(
            "Jellyfin: Found",
            #book_libraries,
            "book libraries"
        )

        if #book_libraries == 0 then
            UIManager:show(InfoMessage:new {
                text = _("No book libraries found"),
            })
        else
            self:showLibrariesMenu(book_libraries)
        end

    else
        logger.err(
            "Jellyfin: Get libraries failed:",
            result
        )

        self:handleApiError(
            result,
            _("Failed to load libraries")
        )
    end
end

function UI:showLibrariesMenu(libraries)
    logger.info(
        "Jellyfin: Showing libraries menu with",
        #libraries,
        "libraries"
    )

    self.current_libraries = libraries

    local items = {}

    for _, lib in ipairs(libraries) do
        table.insert(items, {
            text = lib.Name,
            library = lib,
        })
    end

    local menu

    menu = Menu:new {
        title = _("Select Library"),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,

        onMenuChoice = function(menu_widget, choice)
            logger.info(
                "Jellyfin: Menu choice:",
                choice.text
            )

            UIManager:close(menu_widget)

            local lib = choice.library

            if lib then
                logger.info(
                    "Jellyfin: Library selected:",
                    lib.Name,
                    "ID:",
                    lib.Id
                )

                self:showBooksInLibrary(
                    lib.Id,
                    lib.Name
                )
            end
        end,
    }

    UIManager:show(menu)
end

function UI:showBooksInLibrary(library_id, library_name)
    logger.info(
        "Jellyfin: showBooksInLibrary called with ID:",
        library_id,
        "Name:",
        library_name
    )

    UIManager:show(InfoMessage:new {
        text = _("Loading books..."),
        timeout = 1,
    })

    local success, result =
        self.api:getItemsInLibrary(
            library_id,
            nil,
            0,
            BOOK_BATCH_SIZE
        )

    if success then
        local items = type(result) == "table"
            and type(result.Items) == "table"
            and result.Items
            or {}
        local total = type(result) == "table"
            and tonumber(result.TotalRecordCount)
            or nil
        total = total or #items

        logger.info(
            "Jellyfin: Found",
            total,
            "books"
        )

        if #items == 0 then
            UIManager:show(InfoMessage:new {
                text = _("No books found in this library"),
            })
        else
            self:showBooksMenu(
                items,
                library_name,
                library_id,
                nil,
                total
            )
        end

    else
        logger.err(
            "Jellyfin: Get books failed:",
            result
        )

        self:handleApiError(
            result,
            _("Failed to load books")
        )
    end
end

--[[
Cover handling
]]

function UI:pruneCoverCache()
    if self.cover_cache_pruned then
        return
    end
    self.cover_cache_pruned = true

    local ok_lfs, lfs =
        pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not lfs then
        return
    end

    local ok_scan, files = pcall(function()
        local entries = {}

        for name in lfs.dir(COVER_CACHE_DIR) do
            if name ~= "."
                    and name ~= ".."
                    and name:match("%.jpg$")
            then
                local path =
                    COVER_CACHE_DIR .. "/" .. name
                local attr = lfs.attributes(path)

                if attr and attr.mode == "file" then
                    entries[#entries + 1] = {
                        path = path,
                        modified = attr.modification or 0,
                    }
                end
            end
        end

        return entries
    end)

    if not ok_scan
            or type(files) ~= "table"
            or #files <= COVER_CACHE_PRUNE_AT
    then
        return
    end

    table.sort(files, function(a, b)
        return a.modified < b.modified
    end)

    local remove_count =
        #files - COVER_CACHE_KEEP

    for i = 1, remove_count do
        os.remove(files[i].path)
    end

    collectgarbage("step", 80)
end

function UI:prepareBookCovers(books)
    local changed = false
    local path_ok, path_err =
        util.makePath(COVER_CACHE_DIR)

    if not path_ok then
        logger.warn(
            "Jellyfin: Could not create cover cache:",
            tostring(path_err)
        )
        return false
    end

    self:pruneCoverCache()

    for _, book in ipairs(books or {}) do
        if book
                and book.Id
                and not book._jellyfin_cover_checked
        then
            book._jellyfin_cover_checked = true
            changed = true

            -- Current Jellyfin item queries include Primary image tags.
            -- Avoid a network round-trip for items the server explicitly
            -- reports as having no primary image. Older servers that omit
            -- ImageTags entirely still get the normal download attempt.
            if type(book.ImageTags) == "table"
                    and not book.ImageTags.Primary
            then
                book.cover_path = nil
            else
                local cover_path =
                    COVER_CACHE_DIR
                    .. "/"
                    .. book.Id
                    .. ".jpg"

                if not util.fileExists(cover_path) then
                    local success, error =
                        self.api:downloadBookCover(
                            book.Id,
                            cover_path
                        )

                    if not success then
                        logger.warn(
                            "Jellyfin: Failed to download cover:",
                            book.Name or book.Id,
                            error
                        )
                        cover_path = nil
                    end
                end

                book.cover_path = cover_path
            end
        end
    end

    return changed
end

function UI:queuePageCovers(view)
    self.cover_job_id =
        (self.cover_job_id or 0) + 1

    if not NetworkMgr:isOnline() then
        return
    end

    local job_id = self.cover_job_id
    local books = view:getPageBooks()
    local index = 1
    local changed = false

    local function loadNext()
        if self.cover_job_id ~= job_id
                or self.results_view ~= view
        then
            return
        end

        local book = books[index]
        if not book then
            -- Repaint once after the small visible-page batch instead of
            -- rebuilding the e-ink page after every individual cover.
            if changed then
                view:refresh()
            end
            return
        end

        if self:prepareBookCovers({ book }) then
            changed = true
        end
        index = index + 1

        -- Yield between requests so KOReader can process a page change/close
        -- and cancel the remaining cover work instead of blindly fetching
        -- covers the user is no longer looking at.
        UIManager:scheduleIn(0.01, loadNext)
    end

    UIManager:scheduleIn(0.05, loadNext)
end

function UI:loadMoreBooks(view, target_page)
    if view.loading_more
            or self.results_view ~= view
    then
        return
    end

    view.loading_more = true

    NetworkMgr:runWhenOnline(function()
        UIManager:show(InfoMessage:new {
            text = _("Loading more books..."),
            timeout = 1,
        })

        UIManager:scheduleIn(0.05, function()
            if self.results_view ~= view then
                view.loading_more = false
                return
            end

            local success, result =
                self.api:getItemsInLibrary(
                    view.library_id,
                    view.search_term,
                    #view.books,
                    BOOK_BATCH_SIZE,
                    false
                )

            view.loading_more = false

            if not success then
                self:handleApiError(
                    result,
                    _("Failed to load more books")
                )
                return
            end

            local items =
                type(result) == "table"
                and type(result.Items) == "table"
                and result.Items
                or {}

            -- The first batch owns the authoritative total count. Continuation
            -- batches deliberately disable counting to save server/device work.
            if #items == 0 then
                -- Prevent repeatedly requesting beyond what the server
                -- actually returned if its total count changed meanwhile.
                view.total_count = #view.books
                view:refresh()
                return
            end

            for _, book in ipairs(items) do
                view.books[#view.books + 1] = book
            end

            self.current_books = view.books

            local per_page =
                view.books_per_page
                or BOOKS_PER_PAGE
            local target_last_index =
                math.min(
                    target_page * per_page,
                    view.total_count or #view.books
                )

            if target_last_index <= #view.books then
                view.page = target_page
            end

            view:refresh()
            self:queuePageCovers(view)
        end)
    end)
end

function UI:showBooksMenu(
    books,
    library_name,
    library_id,
    search_term,
    total_count
)
    logger.info(
        "Jellyfin: Showing books menu with",
        #books,
        "books"
    )

    if self.detailed_book then
        self:releaseItemDetails(self.detailed_book)
        self.detailed_book = nil
    end

    self.current_books = books

    if self.results_view then
        UIManager:close(self.results_view)
        self.results_view = nil
    end

    self.results_view = BookResultsView:new {
        ui_handler = self,
        books = books,
        library_id = library_id,
        library_name = library_name,
        search_term = search_term,
        total_count = total_count or #books,
        loading_more = false,
        page = 1,
    }

    UIManager:show(self.results_view)
    self:queuePageCovers(self.results_view)
end

--[[
Search
]]

function UI:searchBooks(
    library_id,
    library_name,
    existing_view
)
    local search_dialog

    search_dialog = InputDialog:new {
        title = _("Search Books"),
        input_hint = _("Enter title or author"),

        buttons = {
            {
                {
                    text = _("Cancel"),

                    callback = function()
                        UIManager:close(search_dialog)
                    end,
                },

                {
                    text = _("Search"),
                    is_enter_default = true,

                    callback = function()
                        local search_term =
                            search_dialog:getInputText()

                        UIManager:close(search_dialog)

                        if not search_term or search_term == "" then
                            return
                        end

                        NetworkMgr:runWhenOnline(function()
                            UIManager:show(InfoMessage:new {
                                text = T(
                                    _("Searching for %1..."),
                                    search_term
                                ),
                                timeout = 1,
                            })

                            local success, result =
                                self.api:getItemsInLibrary(
                                    library_id,
                                    search_term,
                                    0,
                                    BOOK_BATCH_SIZE
                                )

                            if success then
                                local items = type(result) == "table"
                                    and type(result.Items) == "table"
                                    and result.Items
                                    or {}
                                local total = type(result) == "table"
                                    and tonumber(result.TotalRecordCount)
                                    or nil
                                total = total or #items

                                logger.info(
                                    "Jellyfin: Search found",
                                    total,
                                    "books"
                                )

                                if #items == 0 then
                                    UIManager:show(
                                        InfoMessage:new {
                                            text = T(
                                                _("No books found for \"%1\""),
                                                search_term
                                            ),
                                        }
                                    )

                                    return
                                end

                                if self.detailed_book then
                                    self:releaseItemDetails(
                                        self.detailed_book
                                    )
                                    self.detailed_book = nil
                                end

                                self.current_books = items

                                if existing_view then
                                    existing_view:setBooks(
                                        items,
                                        search_term,
                                        total
                                    )
                                else
                                    self:showBooksMenu(
                                        items,
                                        library_name,
                                        library_id,
                                        search_term,
                                        total
                                    )
                                end

                            else
                                logger.err(
                                    "Jellyfin: Search failed:",
                                    result
                                )

                                self:handleApiError(
                                    result,
                                    _("Failed to search books")
                                )
                            end
                        end)
                    end,
                },
            },
        },
    }

    UIManager:show(search_dialog)
    search_dialog:onShowKeyboard()
end

--[[
Book details
]]

function UI:releaseItemDetails(book)
    if not book then
        return
    end

    book.Path = nil
    book.MediaSources = nil
    book.Overview = nil
    book._jellyfin_details_loaded = nil
end

function UI:loadItemDetails(book)
    if book._jellyfin_details_loaded then
        return true
    end

    if not book.Id then
        return false, "invalid_item"
    end

    local success, result =
        self.api:getItemDetails(book.Id)

    if not success then
        return false, result
    end

    if self.detailed_book
            and self.detailed_book ~= book
    then
        self:releaseItemDetails(
            self.detailed_book
        )
    end

    -- Visible result widgets hold references to the original table, so enrich
    -- it in place, but only with fields needed by the details/download path.
    -- This prevents a browsing session from retaining whole Jellyfin DTOs.
    book.Path = result.Path
    book.MediaSources = result.MediaSources
    book.Overview = result.Overview

    if result.People then
        book.People = result.People
    end
    if result.Container then
        book.Container = result.Container
    end
    if result.Type then
        book.Type = result.Type
    end
    if result.UserData then
        book.UserData = result.UserData
    end

    book._jellyfin_details_loaded = true
    self.detailed_book = book
    return true
end

function UI:showBookDetails(book)
    if book._jellyfin_details_loaded then
        self:showBookDetailsLoaded(book)
        return
    end

    NetworkMgr:runWhenOnline(function()
        UIManager:show(InfoMessage:new {
            text = _("Loading book details..."),
            timeout = 1,
        })

        -- Yield once so the loading message can paint before the synchronous
        -- single-item request starts.
        UIManager:scheduleIn(0.05, function()
            local success, error =
                self:loadItemDetails(book)

            if not success then
                self:handleApiError(
                    error,
                    _("Failed to load book details")
                )
                return
            end

            self:prepareBookCovers({ book })
            self:showBookDetailsLoaded(book)
        end)
    end)
end

function UI:showBookDetailsLoaded(book)
    logger.info(
        "Jellyfin: Showing details for book:",
        book.Name
    )

    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    local details_view

    ----------------------------------------------------------------
    -- Layout
    ----------------------------------------------------------------

    local side_margin = Screen:scaleBySize(35)

    local content_width =
        screen_w - (side_margin * 2)

    local cover_width = Screen:scaleBySize(150)
    local cover_height = Screen:scaleBySize(215)

    ----------------------------------------------------------------
    -- Get author
    ----------------------------------------------------------------

    local author = _("Unknown Author")

    if book.People then
        for _, person in ipairs(book.People) do
            if person.Type == "Author" and person.Name then
                author = person.Name
                break
            end
        end

        if author == _("Unknown Author")
            and book.People[1]
            and book.People[1].Name
        then
            author = book.People[1].Name
        end
    end

    ----------------------------------------------------------------
    -- Get description
    ----------------------------------------------------------------

    local description =
        book.Overview
        or _("No description available.")

    description = description:gsub("<br%s*/?>", "\n")
    description = description:gsub("</p>%s*<p>", "\n\n")
    description = description:gsub("<p>", "")
    description = description:gsub("</p>", "")
    description = description:gsub("<[^>]+>", "")
    description = description:gsub("&nbsp;", " ")
    description = description:gsub("&amp;", "&")
    description = description:gsub("&lt;", "<")
    description = description:gsub("&gt;", ">")

    ----------------------------------------------------------------
    -- Title bar
    ----------------------------------------------------------------

    local titlebar = TitleBar:new {
        width = screen_w,
        align = "left",
        title = _("Book Details"),

        close_callback = function()
            if details_view then
                UIManager:close(details_view)
            end
        end,

        show_parent = self,
    }

    ----------------------------------------------------------------
    -- Cover
    ----------------------------------------------------------------

    local cover

    if book.cover_path and util.fileExists(book.cover_path) then
        cover = ImageWidget:new {
            file = book.cover_path,
            width = cover_width,
            height = cover_height,
            scale_factor = 0,
        }
    else
        cover = FrameContainer:new {
            width = cover_width,
            height = cover_height,

            background = Blitbuffer.COLOR_LIGHT_GRAY,

            bordersize = 1,
            bordercolor = Blitbuffer.COLOR_GRAY_3,

            CenterContainer:new {
                dimen = {
                    w = cover_width,
                    h = cover_height,
                },

                TextWidget:new {
                    text = _("No Cover"),
                    face = Font:getFace("smallinfofont"),
                },
            },
        }
    end

    ----------------------------------------------------------------
    -- Title
    ----------------------------------------------------------------

    local info_width =
        content_width
        - cover_width
        - Screen:scaleBySize(25)

    if info_width < Screen:scaleBySize(100) then
        info_width = Screen:scaleBySize(100)
    end

    local title_widget = TextBoxWidget:new {
        text = book.Name or _("Untitled"),

        width = info_width,
        height = Screen:scaleBySize(85),

        face = Font:getFace("tfont"),
        alignment = "left",
    }

    ----------------------------------------------------------------
    -- Author
    ----------------------------------------------------------------

    local author_widget = TextBoxWidget:new {
        text = author,

        width = info_width,
        height = Screen:scaleBySize(45),

        face = Font:getFace("smallinfofont"),
        alignment = "left",
    }

    ----------------------------------------------------------------
    -- Download button
    ----------------------------------------------------------------

    local download_button = Button:new {
        text = _("Download"),

        callback = function()
            UIManager:close(details_view)
            self:downloadBook(book)
        end,
    }

    ----------------------------------------------------------------
    -- Read / unread button
    ----------------------------------------------------------------

    local read_button

    read_button = Button:new {
        text =
            book.UserData
            and book.UserData.Played
            and _("Mark as Unread")
            or _("Mark as Read"),

        callback = function()
            self:toggleReadStatus(
                book,
                read_button
            )
        end,
    }

    ----------------------------------------------------------------
    -- Book information
    ----------------------------------------------------------------

    local book_info = VerticalGroup:new {
        align = "left",

        title_widget,

        VerticalSpan:new {
            height = Screen:scaleBySize(8),
        },

        author_widget,
    }

    ----------------------------------------------------------------
    -- Cover + title + author
    ----------------------------------------------------------------

    local header = CenterContainer:new {
        dimen = {
            w = content_width,
            h = cover_height,
        },

        HorizontalGroup:new {
            align = "center",

            cover,

            HorizontalSpan:new {
                width = Screen:scaleBySize(25),
            },

            book_info,
        },
    }

    ----------------------------------------------------------------
    -- Buttons
    ----------------------------------------------------------------

    local action_buttons = CenterContainer:new {
        dimen = {
            w = content_width,
            h = Screen:scaleBySize(55),
        },

        HorizontalGroup:new {
            align = "center",

            download_button,

            HorizontalSpan:new {
                width = Screen:scaleBySize(15),
            },

            read_button,
        },
    }

    ----------------------------------------------------------------
    -- Description heading
    ----------------------------------------------------------------

    local description_title = CenterContainer:new {
        dimen = {
            w = content_width,
            h = Screen:scaleBySize(35),
        },

        TextWidget:new {
            text = _("About This Book"),
            face = Font:getFace("tfont"),
        },
    }

    ----------------------------------------------------------------
    -- Description
    ----------------------------------------------------------------

    local description_width =
        math.min(
            content_width,
            Screen:scaleBySize(560)
        )

    local description_widget = TextBoxWidget:new {
        text = description,

        width = description_width,

        face = Font:getFace("cfont"),
        alignment = "left",
    }

    local description_size = description_widget:getSize()

    local description_height = description_size.h

    if description_height < Screen:scaleBySize(30) then
        description_height = Screen:scaleBySize(30)
    end

    ----------------------------------------------------------------
    -- Description container
    ----------------------------------------------------------------

    local description_container = CenterContainer:new {
        dimen = {
            w = content_width,
            h = description_height,
        },

        description_widget,
    }

    ----------------------------------------------------------------
    -- Spacing
    ----------------------------------------------------------------

    local top_spacing = Screen:scaleBySize(25)
    local header_spacing = Screen:scaleBySize(22)
    local button_spacing = Screen:scaleBySize(25)
    local description_spacing = Screen:scaleBySize(8)
    local bottom_spacing = Screen:scaleBySize(30)

    ----------------------------------------------------------------
    -- Calculate complete content height
    ----------------------------------------------------------------

    local content_height =
        top_spacing
        + cover_height
        + header_spacing
        + Screen:scaleBySize(55)
        + button_spacing
        + Screen:scaleBySize(35)
        + description_spacing
        + description_height
        + bottom_spacing

    ----------------------------------------------------------------
    -- Entire page content
    ----------------------------------------------------------------

    local scroll_content = VerticalGroup:new {
        width = content_width,

        align = "left",

        VerticalSpan:new {
            height = top_spacing,
        },

        header,

        VerticalSpan:new {
            height = header_spacing,
        },

        action_buttons,

        VerticalSpan:new {
            height = button_spacing,
        },

        description_title,

        VerticalSpan:new {
            height = description_spacing,
        },

        description_container,

        VerticalSpan:new {
            height = bottom_spacing,
        },
    }

    scroll_content:getSize()

    ----------------------------------------------------------------
    -- Scroll viewport
    ----------------------------------------------------------------

    local scroll_height =
        screen_h - titlebar:getHeight()

    local scroll_view = ScrollableContainer:new {
        dimen = Geom:new {
            x = 0,
            y = 0,
            w = screen_w,
            h = scroll_height,
        },

        CenterContainer:new {
            dimen = {
                w = screen_w,
                h = content_height,
            },

            scroll_content,
        },
    }

    ----------------------------------------------------------------
    -- Main details window
    ----------------------------------------------------------------

    details_view = InputContainer:new {
        width = screen_w,
        height = screen_h,

        dimen = Geom:new {
            x = 0,
            y = 0,
            w = screen_w,
            h = screen_h,
        },

        FrameContainer:new {
            width = screen_w,
            height = screen_h,

            background = Blitbuffer.COLOR_WHITE,

            VerticalGroup:new {
                align = "left",

                titlebar,

                scroll_view,
            },
        },
    }

    ----------------------------------------------------------------
    -- Required by ScrollableContainer
    ----------------------------------------------------------------

    details_view.cropping_widget = scroll_view

    scroll_view.show_parent = details_view

    ----------------------------------------------------------------
    -- Show
    ----------------------------------------------------------------

    UIManager:show(details_view)
end

--[[
Download functionality
]]

function UI:downloadBook(book)
    if not book._jellyfin_details_loaded then
        NetworkMgr:runWhenOnline(function()
            local success, error =
                self:loadItemDetails(book)

            if success then
                self:downloadBook(book)
            else
                self:handleApiError(
                    error,
                    _("Failed to load download information")
                )
            end
        end)
        return
    end

    logger.info(
        "Jellyfin: Starting download for book:",
        book.Name,
        "ID:",
        book.Id
    )

    NetworkMgr:runWhenOnline(function()
        local extension = itemExtension(book)
        local filename =
            sanitizeFilename(book.Name, book.Id or "item")
            .. extension

        local download_dir

        if isAudiobook(book) then
            download_dir =
                DataStorage:getDataDir()
                .. "/books/AudioBooks/"
        else
            download_dir =
                DataStorage:getDataDir()
                .. "/books/eBooks/"
        end

        local path_ok, path_err = util.makePath(download_dir)
        if not path_ok then
            logger.err(
                "Jellyfin: Could not create download directory:",
                tostring(path_err)
            )
            UIManager:show(InfoMessage:new {
                text = T(
                    _("Could not create the download folder:\n%1"),
                    download_dir
                ),
            })
            return
        end

        local filepath =
            download_dir .. filename

        logger.info(
            "Jellyfin: Download destination:",
            filepath
        )

        local media_source =
            type(book.MediaSources) == "table"
            and book.MediaSources[1]
            or nil
        local expected_size =
            media_source
            and tonumber(media_source.Size)
            or nil

        local progress_dialog = ProgressbarDialog:new {
            title = _("Downloading"),
            subtitle = book.Name or filename,
            progress_max =
                expected_size
                and expected_size > 0
                and expected_size
                or nil,
            refresh_time_seconds = 1.0,
            dismissable = false,
        }

        progress_dialog:show()

        -- The transfer is synchronous. Delay it briefly so KOReader gets a
        -- chance to paint the download dialog before the socket starts
        -- blocking the normal event loop.
        UIManager:scheduleIn(0.1, function()
            local progress_callback

            if expected_size and expected_size > 0 then
                progress_callback = function(downloaded)
                    progress_dialog:reportProgress(
                        math.min(downloaded, expected_size)
                    )
                end
            end

            local ok_download, success, error =
                pcall(
                    self.api.downloadItem,
                    self.api,
                    book.Id,
                    filepath,
                    progress_callback
                )

            if not ok_download then
                error = tostring(success)
                success = false
                os.remove(filepath .. ".part")
                logger.err(
                    "Jellyfin: Download raised an error:",
                    error
                )
            end

            if success and expected_size and expected_size > 0 then
                progress_dialog:reportProgress(expected_size)
            end

            if success and isAudiobook(book) then
                logger.info("Jellyfin: Audiobook detected.")

                local sdr_directory =
                    filepath:gsub("%.[^%.]+$", ".sdr")
                local cover_filepath =
                    sdr_directory .. "/cover.jpg"

                local sdr_ok, sdr_err =
                    util.makePath(sdr_directory)

                if sdr_ok then
                    local cover_success = false
                    local cover_error

                    -- The visible library/details screen normally cached this
                    -- exact 320px Jellyfin cover already. Reuse it instead of
                    -- making a second network request for the sidecar.
                    if book.cover_path
                            and util.fileExists(book.cover_path)
                    then
                        local copy_error =
                            FFIUtil.copyFile(
                                book.cover_path,
                                cover_filepath
                            )

                        if copy_error == nil then
                            cover_success = true
                        else
                            cover_error = copy_error
                        end
                    end

                    if not cover_success then
                        cover_success, cover_error =
                            self.api:downloadBookCover(
                                book.Id,
                                cover_filepath
                            )
                    end

                    if not cover_success then
                        logger.warn(
                            "Jellyfin: Audiobook downloaded, but cover download failed:",
                            cover_error
                        )
                    end
                else
                    logger.warn(
                        "Jellyfin: Audiobook downloaded, but sidecar directory creation failed:",
                        tostring(sdr_err)
                    )
                end
            end

            progress_dialog:close()

            if success then
                logger.info(
                    "Jellyfin: Download completed successfully:",
                    filepath
                )

                UIManager:nextTick(function()
                    if isAudiobook(book) then
                        UIManager:show(InfoMessage:new {
                            text = T(
                                _("Audiobook downloaded to:\n%1"),
                                filepath
                            ),
                        })
                    else
                        UIManager:show(ConfirmBox:new {
                            text = T(
                                _("Book downloaded to:\n%1\n\nOpen now?"),
                                filepath
                            ),

                            ok_callback = function()
                                logger.info(
                                    "Jellyfin: Opening downloaded book:",
                                    filepath
                                )

                                local ReaderUI =
                                    require("apps/reader/readerui")

                                ReaderUI:showReader(filepath)
                            end,
                        })
                    end
                end)
            else
                logger.err(
                    "Jellyfin: Download failed:",
                    error
                )

                UIManager:nextTick(function()
                    self:handleApiError(
                        error,
                        _("Failed to download book")
                    )
                end)
            end
        end)
    end)
end

--[[
Existing read/unread functionality
]]

function UI:toggleReadStatus(book, read_button)
    logger.info(
        "Jellyfin: Toggling read status for book:",
        book.Name
    )

    NetworkMgr:runWhenOnline(function()
        local is_played =
            book.UserData
            and book.UserData.Played

        UIManager:show(InfoMessage:new {
            text = _("Updating status..."),
            timeout = 1,
        })

        local success, error =
            self.api:setPlayedStatus(
                book.Id,
                not is_played
            )

        if success then
            book.UserData = book.UserData or {}
            book.UserData.Played = not is_played

            if read_button then
                local new_text =
                    book.UserData.Played
                    and _("Mark as Unread")
                    or _("Mark as Read")

                read_button:setText(
                    new_text,
                    read_button.width
                )
                read_button:refresh()
            end

            if self.results_view then
                self.results_view:refresh()
            end

            UIManager:show(InfoMessage:new {
                text =
                    is_played
                    and _("Marked as unread")
                    or _("Marked as read"),
            })
        else
            logger.err(
                "Jellyfin: Update status failed:",
                error
            )

            UIManager:show(InfoMessage:new {
                text = T(
                    _("Failed to update status (code %1)"),
                    error
                ),
            })
        end
    end)
end

return UI