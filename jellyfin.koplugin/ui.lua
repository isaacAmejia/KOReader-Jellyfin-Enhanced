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

local function itemExtension(book)
    local path = book and book.Path

    if (not path or path == "")
            and book
            and type(book.MediaSources) == "table"
            and book.MediaSources[1]
    then
        path = book.MediaSources[1].Path
    end

    local ext = path and path:match("%.([^./\\]+)$")
    if ext and #ext <= 12 then
        return "." .. ext:lower()
    end

    return book and book.Type == "AudioBook" and ".m4b" or ".epub"
end

local COVER_CACHE_DIR = DataStorage:getDataDir() .. "/jellyfin_covers"
local BOOKS_PER_PAGE = 5

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
    if #self.books == 0 then
        return 1
    end

    return math.ceil(#self.books / BOOKS_PER_PAGE)
end

function BookResultsView:getPageBooks()
    local start_index = ((self.page - 1) * BOOKS_PER_PAGE) + 1

    local end_index = math.min(
        start_index + BOOKS_PER_PAGE - 1,
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
            UIManager:close(self)

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

    local row_height = math.floor(
        (self.screen_h - content_top - footer_height)
        / BOOKS_PER_PAGE
    )

    if row_height < Screen:scaleBySize(75) then
        row_height = Screen:scaleBySize(75)
    end

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

    while #rows < BOOKS_PER_PAGE do
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
    self:build()

    UIManager:setDirty(
        self,
        "full"
    )
end

function BookResultsView:setBooks(books, search_term)
    self.books = books or {}
    self.search_term = search_term
    self.page = 1

    self:refresh()
end

function BookResultsView:previousPage()
    if self.page <= 1 then
        return
    end

    self.page = self.page - 1
    self:refresh()
end

function BookResultsView:nextPage()
    if self.page >= self:getPageCount() then
        return
    end

    self.page = self.page + 1
    self:refresh()
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

    else
        UIManager:show(InfoMessage:new {
            text = T(
                _("%1 (code %2)"),
                default_msg,
                error_code
            ),
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
        logger.info(
            "Jellyfin: Response has",
            #result.Items,
            "total items"
        )

        local book_libraries = {}

        for _, item in ipairs(result.Items) do
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

        if result == "parse_error" then
            UIManager:show(InfoMessage:new {
                text = _("Failed to parse server response"),
            })
        else
            UIManager:show(InfoMessage:new {
                text = T(
                    _("Failed to load libraries (code %1)"),
                    result
                ),
            })
        end
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

            for _, lib in ipairs(self.current_libraries) do
                if lib.Name == choice.text then
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

                    break
                end
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
        self.api:getItemsInLibrary(library_id)

    if success then
        logger.info(
            "Jellyfin: Found",
            result.TotalRecordCount,
            "books"
        )

        if result.TotalRecordCount == 0 then
            UIManager:show(InfoMessage:new {
                text = _("No books found in this library"),
            })
        else
            self:showBooksMenu(
                result.Items,
                library_name,
                library_id
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

function UI:prepareBookCovers(books)
    util.makePath(COVER_CACHE_DIR)

    for _, book in ipairs(books) do
        local cover_path =
            COVER_CACHE_DIR .. "/" .. book.Id .. ".jpg"

        if not util.fileExists(cover_path) then
            logger.info(
                "Jellyfin: Downloading cover for:",
                book.Name
            )

            local success, error =
                self.api:downloadBookCover(
                    book.Id,
                    cover_path
                )

            if not success then
                logger.warn(
                    "Jellyfin: Failed to download cover:",
                    book.Name,
                    error
                )

                cover_path = nil
            end
        end

        book.cover_path = cover_path
    end
end

--[[
Book results
]]

function UI:showBooksMenu(
    books,
    library_name,
    library_id,
    search_term
)
    logger.info(
        "Jellyfin: Showing books menu with",
        #books,
        "books"
    )

    self.current_books = books

    NetworkMgr:runWhenOnline(function()
        self:prepareBookCovers(books)

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
            page = 1,
        }

        UIManager:show(self.results_view)
    end)
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
                                    search_term
                                )

                            if success then
                                logger.info(
                                    "Jellyfin: Search found",
                                    result.TotalRecordCount,
                                    "books"
                                )

                                if result.TotalRecordCount == 0 then
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

                                self.current_books = result.Items

                                self:prepareBookCovers(
                                    result.Items
                                )

                                if existing_view then
                                    existing_view:setBooks(
                                        result.Items,
                                        search_term
                                    )
                                else
                                    self:showBooksMenu(
                                        result.Items,
                                        library_name,
                                        library_id,
                                        search_term
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

function UI:showBookDetails(book)
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

    local read_button = Button:new {
        text =
            book.UserData
            and book.UserData.Played
            and _("Mark as Unread")
            or _("Mark as Read"),

        callback = function()
            self:toggleReadStatus(book)
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

        if book.Type == "AudioBook" then
            download_dir =
                DataStorage:getDataDir()
                .. "/books/AudioBooks/"
        else
            download_dir =
                DataStorage:getDataDir()
                .. "/books/eBooks/"
        end

        util.makePath(download_dir)

        local filepath =
            download_dir .. filename

        logger.info(
            "Jellyfin: Download destination:",
            filepath
        )

        UIManager:show(InfoMessage:new {
            text = T(
                _("Downloading %1..."),
                book.Name
            ),
            timeout = 2,
        })

        logger.info(
            "Jellyfin: Calling API downloadItem..."
        )

        local success, error =
            self.api:downloadItem(
                book.Id,
                filepath
            )

        logger.info(
            "Jellyfin: downloadItem returned. Success:",
            success,
            "Error:",
            error or "none"
        )

        if success then
            logger.info(
                "Jellyfin: Download completed successfully:",
                filepath
            )

            UIManager:nextTick(function()
                logger.info(
                    "Jellyfin: Processing post-download UI for:",
                    book.Name
                )

                if book.Type == "AudioBook" then
                    logger.info("Jellyfin: Audiobook detected.")

                    local sdr_directory =
                        filepath:gsub("%.[^%.]+$", ".sdr")
                    local cover_filepath =
                        sdr_directory .. "/cover.jpg"

                    -- Create the sidecar ourselves instead of relying on a
                    -- specific device, library UI, or timing behavior.
                    util.makePath(sdr_directory)

                    local cover_success, cover_error =
                        self.api:downloadBookCover(
                            book.Id,
                            cover_filepath
                        )

                    if not cover_success then
                        logger.warn(
                            "Jellyfin: Audiobook downloaded, but cover download failed:",
                            cover_error
                        )
                    end

                    UIManager:show(InfoMessage:new {
                        text = T(
                            _("Audiobook downloaded to:\n%1"),
                            filepath
                        ),
                    })

                else
                    logger.info(
                        "Jellyfin: Book detected, showing open prompt."
                    )

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
end
--[[
Existing read/unread functionality
]]

function UI:toggleReadStatus(book)
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
            if book.UserData then
                book.UserData.Played = not is_played
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