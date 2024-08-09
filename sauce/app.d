import std.stdio;
import std.string;
import std.file;
import std.path;
import std.conv;
import std.algorithm;
import std.process;
import std.ascii;
import core.stdc.stdlib;
import core.sys.posix.sys.stat;
import deimos.ncurses;

// TODO: visual indicator for when file is symlink
// TODO: config file
// TODO: maybe have a different color for executables too
// TODO: allow for mapping keys to running external scripts
// TODO: bookmarks
// TODO: multiple tabs
// TODO: make selection work between multiple instances
//      (like, save them to a temp file and read it back when it gets modified)
// TODO: toggleable split pane (with a file/directory preview)
// TODO: allow for use as a file picker?

const ubyte COLOR_DIR     = COLOR_BLUE;
const ubyte COLOR_FILE    = COLOR_WHITE;
const ubyte COLOR_STATUS  = COLOR_RED;

const string[] SCRIPTS_PATHS = [
    "$HOME/ff/scripts/",
    "$HOME/.config/ff/scripts",
];

// ???????????????????
int ctrl(int ch)
{
    return ch & 0x1f;
}

enum ColorPairs
{
    FILE = 1,
    DIR,
    STATUS,
    // TODO: executables???
}

struct Input
{
    string text;
    uint cursor;
    bool active;

    void activate()
    {
        active = true;
        cursor = 0;
        text = "";
    }

    void draw(int x, int y, uint max_w)
    {
        foreach (i; 0..max_w) mvprintw(y, x+i, " ");
        mvprintw(y, x, "%.*s", min(text.length, max_w), text.toStringz);
        char ch = (cursor < text.length && text[cursor].isPrintable)? text[cursor] : ' ';
        attron(A_REVERSE);
        mvprintw(y, x+cursor, "%c", ch);
        attroff(A_REVERSE);
    }

    bool update(int ch)
    {
        switch (ch) {
        case KEY_LEFT:
            if (cursor > 0)
                --cursor;
            break;
        case KEY_RIGHT:
            if (cursor < text.length)
                ++cursor;
            break;
        case KEY_HOME:
            cursor = 0;
            break;
        case KEY_END:
            cursor = to!uint(text.length);
            break;
        case KEY_DC:
            delCharacter();
            break;
        case KEY_BACKSPACE:
            if (cursor == 0) break;
            --cursor;
            delCharacter();
            break;
        case '\n':
            active = false;
            return true;
        case ctrl('c'):
        case ctrl('q'):
            active = false;
            break;
        default:
            if (ch.isPrintable)
                addCharacter(ch);
            break;
        }
        return false;
    }

    void addCharacter(int ch)
    {
        if (cursor == text.length)
            text ~= ch;
        else
            text = text[0..cursor] ~ to!char(ch) ~ text[cursor..$];
        ++cursor;
    }

    void delCharacter()
    {
        if (cursor == text.length) return;
        text = text[0..cursor] ~ text[cursor+1..$];
    }
}

struct Entry
{
    string path;
    string name;
    /* ulong size; */

    bool isDir()
    {
        return fullName.isDir;
    }

    bool isExec()
    {
        auto stat = DirEntry(fullName).statBuf();
        return (!(stat.st_mode & S_IFDIR)) && (stat.st_mode & S_IXUSR);
    }

    string fullName()
    {
        return path ~ "/" ~ name;
    }
}

enum InputAction {
    NONE,
    FIND,
    EXEC,
    OPEN,
}

string actionToString(InputAction s) {
    switch (s) {
    case InputAction.FIND: return "Find: ";
    case InputAction.EXEC: return "Run: ";
    case InputAction.OPEN: return "Open: ";
    default: return "None: ";
    }
}

struct FuckFiles
{
    Entry[] entries;
    Entry[] selected;

    bool show_hidden;
    string path; // current path
    int pos;     // currently hovered file
    int off;     // cursor offset
    int screen_w, screen_h;
    Input inputbox;
    InputAction action;

    this(bool hidden)
    {
        show_hidden = hidden;
        inputbox = Input("", 0);
    }

    string selectedEntriesAsString()
    {
        return selected.map!(e => e.fullName).join(" ");
    }

    string lookForScriptInPath(string script)
    {
        foreach (p; SCRIPTS_PATHS) {
            auto r = p.replace("$HOME", environment.get("HOME"));
            if ((r ~ '/' ~ script).exists)
                return r ~ '/' ~ script;
        }
        return null;
    }

    void spawnInPath(string path, string cmd)
    {
        quit();
        auto script = lookForScriptInPath(cmd.split[0]);
        // if script exists, replace cmd with it (is this dumb? maybe?)
        if (script.length) cmd = script ~ ' ' ~ cmd.split[1..$].join(' ');

        // D doesn't have named arguments. i can't just set 'path' and 'env'
        // and leave everything else as default. literally unusable ffs
        spawnShell(
                cmd,
                std.stdio.stdin,
                std.stdio.stdout,
                std.stdio.stderr,
                ["sel": selectedEntriesAsString],
                Config.none,
                path,
                nativeShell).wait;
        removeTheFilesThatNoLongerExistFromSelection();
        init();
    }

    void listEntries(string p)
    {
        if (!p.exists || !p.isDir)
            die("Directory '" ~ p ~ "' does not exist.");

        path = p;
        entries = []; // long live garbage collection
        Entry[] dir_entries;
        Entry[] file_entries;

        foreach (e; path.dirEntries(SpanMode.shallow)) {
            try {
                auto name = e.name.split("/")[$-1];
                if (name[0] == '.' && !show_hidden) continue;
                auto entry = Entry(path, name); // , e.size);
                if (e.name.isDir) dir_entries ~= entry;
                else file_entries ~= entry;
            } catch (Exception) continue;
        }

        sort!((a, b) => a.name.toLower < b.name.toLower)(dir_entries);
        sort!((a, b) => a.name.toLower < b.name.toLower)(file_entries);
        entries = dir_entries ~ file_entries;
    }

    void renderEntries()
    {
        if (!entries.length) {
            attron(A_REVERSE|A_BOLD);
            mvprintw(1, 0, " empty ");
            attroff(A_REVERSE|A_BOLD);
            return;
        }

        foreach (i; off..off+screen_h-3) { // capped
            if (i >= entries.length) break;
            attron(entries[i].isDir? COLOR_PAIR(ColorPairs.DIR)|A_BOLD : COLOR_PAIR(ColorPairs.FILE));
            if (pos == i) attron(A_REVERSE);

            auto name = (entries[i].name.length > screen_w-2)? entries[i].name[0..screen_w-2] : entries[i].name;
            auto sel = (selected.canFind(entries[i])? " * " : " ");
            mvprintw(i - off + 1, 0, (sel ~ name).toStringz);
            printw(entries[i].isExec? "*" : "");

            if (pos == i) attroff(A_REVERSE);
            attroff(entries[i].isDir? COLOR_PAIR(ColorPairs.DIR)|A_BOLD : COLOR_PAIR(ColorPairs.FILE));
        }
    }

    void render()
    {
        getmaxyx(stdscr, screen_h, screen_w);
        erase();
        renderEntries();

        attron(COLOR_PAIR(ColorPairs.STATUS));
        mvprintw(screen_h-1, 0, "[%d] (%d/%d) %s  ",
                selected.length, pos+1, entries.length, path.toStringz);
        attroff(COLOR_PAIR(ColorPairs.STATUS));

        if (inputbox.active) {
            auto text = action.actionToString;
            mvprintw(screen_h-1, 0, text.toStringz);
            inputbox.draw(text.length.to!int, screen_h-1, screen_w-1);
        }
    }

    void update()
    {
        int ch = getch();
        if (inputbox.active) {
            if (inputbox.update(ch) && inputbox.text.length)
                performActionBasedOnInputAction(inputbox.text);
            return;
        }
        // TODO: get keys from a config file
        switch (ch) {
        case ctrl('q'): case ctrl('c'):
        case 'q': case 'Q':
            quit();
            write_last_dir(path);
            exit(0);
        case ctrl('r'):
        case 'r': case 'R':
            moveCursor(0);
            listEntries(path);
            break;
        case 'u':
            selected = [];
            break;
        case 'w':
            focusFirstEntry((e) => !e.isDir);
            break;
        case 'W':
            focusFirstEntry((e) => e.isDir);
            break;
        case 'g':
        case KEY_HOME:
            pos = 0;
            moveCursor(0);
            break;
        case 'G':
        case KEY_END:
            pos = cast(int) entries.length-1;
            moveCursor(0);
            break;
        case KEY_PPAGE:
            movePage(-1);
            break;
        case KEY_NPAGE:
            movePage(1);
            break;
        case 'j':
        case KEY_DOWN:
            moveCursor(1);
            break;
        case 'k':
        case KEY_UP:
            moveCursor(-1);
            break;
        case 'h':
        case KEY_LEFT:
            openPrevDir();
            break;
        case 'l':
        case '\n':
        case KEY_RIGHT:
            if (!entries.length) break;
            openFile(entries[pos]);
            break;
        case 'e':
            if (!entries.length) break;
            editFile(entries[pos]);
            break;
        case 's':
        case 'S':
            openShell();
            break;
        case ' ':
            if (!entries.length) break;
            if (selected.canFind(entries[pos]))
                selected = selected.remove(selected.countUntil(entries[pos]));
            else
                selected ~= entries[pos];
            if (pos < entries.length-1)
                moveCursor(1);
            break;
        case 'a':
            foreach (entry; entries)
                if (!selected.canFind(entry))
                    selected ~= entry;
            break;
        case 'v':
            foreach (entry; entries)
                if (selected.canFind(entry))
                    selected = selected.remove(selected.countUntil(entry));
                else
                    selected ~= entry;
            break;
        case '.':
            show_hidden = !show_hidden;
            listEntries(path);
            moveCursor(0);
            // TODO: cursor follow selected file (if dotfiles appear before it, move cursor down with it)
            break;
        case 'n':
            if (inputbox.text.length && action == InputAction.FIND && entries.length)
                searchNext(inputbox.text);
            break;
        case 'N':
            if (inputbox.text.length && action == InputAction.FIND && entries.length)
                searchPrev(inputbox.text);
            break;
        case ctrl('f'):
        case '/':
            action = InputAction.FIND;
            inputbox.activate();
            break;
        case ':':
            action = InputAction.EXEC;
            inputbox.activate();
            break;
        case 'o':
            if (!entries.length) break;
            action = InputAction.OPEN;
            inputbox.activate();
            break;
        default:
            break;
        }
    }

    // always good to name your functions things that are easy to understand.
    void removeTheFilesThatNoLongerExistFromSelection()
    {
        foreach (sel; selected) {
            if (!sel.fullName.exists)
                selected = selected.remove(selected.countUntil(sel));
        }
    }

    void performActionBasedOnInputAction(string text)
    {
        switch (action) {
        case InputAction.FIND:
            searchNext(text);
            break;
        case InputAction.EXEC:
            spawnInPath(path, text);
            listEntries(path);
            moveCursor(0);
            break;
        case InputAction.OPEN:
            openFileWith(entries[pos], text);
            break;
        default:
            break;
        }
    }

    void openPrevDir()
    {
        string prev, curr;
        auto p = path.split("/");
        prev = (p.length == 2)? "/" : p[0..$-1].join("/");
        curr = p[$-1];

        if (!prev.exists)
            return;
        openDir(prev);

        foreach (i; 0..entries.length) {
            if (entries[i].name == curr) {
                pos = cast(int) i;
                break;
            }
        }
        moveCursor(0);
    }

    void openDir(string path)
    {
        path = path.startsWith("//")? path[1..$] : path;
        listEntries(path);
        // XXX: maybe save directories i already opened and select last selected file from that directory
        pos = off = 0;
    }

    void openFile(Entry file)
    {
        if (file.isDir)
            return openDir(file.fullName);
        spawnInPath(file.path, format("xdg-open \"%s\"", file.name));
    }

    void openFileWith(Entry file, string cmd)
    {
        auto prog = "\"" ~ file.name ~ "\"";
        if (selected.length)
            prog = selected.map!(s => "\"" ~ s.fullName ~ "\"").join(" ");
        spawnInPath(file.path, format("%s %s", cmd, prog));
        moveCursor(0);
        listEntries(path);
    }

    void editFile(Entry file)
    {
        spawnInPath(file.path, format("$EDITOR \"%s\"", file.name));
    }

    void openShell()
    {
        spawnInPath(path, "$SHELL");
        // in case a file has changed
        moveCursor(0);
        listEntries(path);
    }

    bool findFile(Entry file, string text, ulong idx)
    {
        // TODO: maybe some sort of fuzzy find
        if (entries[idx].name.toLower.canFind(text.toLower)) {
            pos = idx.to!int;
            moveCursor(0);
            return true;
        }
        return false;
    }

    bool searchFile(string text, int s, int e, int inc)
    {
        if (!entries.length) return false;
        for (auto i = s; (s < e && i < e) || (s > e && i > e); i += inc) {
            if (findFile(entries[i], text, i))
                return true;
        }
        return false;
    }

    void searchNext(string text)
    {
        if (!searchFile(text, pos+1, entries.length.to!int, 1))
            searchFile(text, 0, pos, 1);
    }

    void searchPrev(string text)
    {
        if (!searchFile(text, pos-1, 0, -1))
            searchFile(text, entries.length.to!int-1, pos-1, -1);
    }

    void focusFirstEntry(bool function(Entry) f)
    {
        foreach (i, entry; entries) {
            if (f(entry)) {
                pos = i.to!int;
                break;
            }
        }
        moveCursor(0);
    }

    void moveCursor(int p)
    {
        // TODO: better scrolling... maybe
        pos += p;
        if (pos < 0) pos = cast(int) entries.length-1;
        if (pos >= entries.length) pos = 0;
        off = (pos > screen_h/2)? (pos - screen_h/2) : 0;
    }

    void movePage(int p)
    {
        foreach (i; 0..screen_h-3) {
            if (pos+p < 0 || pos+p >= entries.length)
                break;
            moveCursor(p);
        }
    }
}

void init()
{
    initscr();
    raw();
    noecho();
    curs_set(0);
    keypad(stdscr, true);

    use_default_colors();
    start_color();
    init_pair(ColorPairs.FILE, COLOR_FILE, -1);
    init_pair(ColorPairs.DIR, COLOR_DIR, -1);
    init_pair(ColorPairs.STATUS, COLOR_STATUS, -1);
}

void quit()
{
    endwin();
    curs_set(1);
}

void write_last_dir(string dir)
{
    std.file.write(environment.get("HOME") ~ "/.ffdir", dir);
}

void die(string err)
{
    quit();
    stderr.writefln("error: %s", err);
    exit(1);
}

void main()
{
    auto files = FuckFiles();
    init();
    scope(exit) {
        write_last_dir(files.path);
        quit();
    }

    files.listEntries(getcwd());

    for (;;) {
        files.render();
        files.update();
    }
}
