// cl-window: the cl web UI in its own desktop window (GTK 4 + WebKitGTK 6).
//
//   cl-window <url> <data dir>
//
// `cl window` starts it; it isn't meant to be run by hand. The web view has
// no browser shortcuts of its own, so keys like Ctrl+W, Ctrl+T, Ctrl+L and
// Ctrl+R reach the page (the terminal). The window's own keys all use
// Ctrl+Shift: R reloads, +/-/0 zoom, I opens the web inspector.
//
// Cookies (the sign-in) and local storage live in <data dir>, and the window
// remembers its page, size and zoom there, so reopening it comes back to the
// same place. One window per user: a second launch raises the first.
#include <gtk/gtk.h>
#include <webkit/webkit.h>

#define APP_ID "io.github.jself.cl"

static const char *start_url;
static const char *data_dir;
static char *origin; // scheme://host:port of start_url
static GtkWindow *window;
static WebKitWebView *view;

static char *state_path(void) { return g_build_filename(data_dir, "window.ini", NULL); }

static char *origin_of(const char *uri) {
    GUri *u = g_uri_parse(uri, G_URI_FLAGS_NONE, NULL);
    if (!u) return g_strdup("");
    char *o = g_strdup_printf("%s://%s:%d", g_uri_get_scheme(u), g_uri_get_host(u) ? g_uri_get_host(u) : "", g_uri_get_port(u));
    g_uri_unref(u);
    return o;
}

static gboolean same_origin(const char *uri) {
    char *o = origin_of(uri);
    gboolean same = g_str_equal(o, origin);
    g_free(o);
    return same;
}

static void open_outside(const char *uri) {
    GtkUriLauncher *l = gtk_uri_launcher_new(uri);
    gtk_uri_launcher_launch(l, window, NULL, NULL, NULL);
    g_object_unref(l);
}

// Links to other sites, and anything opened in a new window (the gutter
// review), go to the default browser; the window stays on cl.
static gboolean on_decide_policy(WebKitWebView *v, WebKitPolicyDecision *d, WebKitPolicyDecisionType type, gpointer _) {
    (void)v;
    if (type != WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION && type != WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION) return FALSE;
    WebKitNavigationAction *a = webkit_navigation_policy_decision_get_navigation_action(WEBKIT_NAVIGATION_POLICY_DECISION(d));
    const char *uri = webkit_uri_request_get_uri(webkit_navigation_action_get_request(a));
    if (type == WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION && (same_origin(uri) || g_str_has_prefix(uri, "about:"))) return FALSE;
    if (webkit_navigation_action_is_user_gesture(a) || type == WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION) open_outside(uri);
    webkit_policy_decision_ignore(d);
    return TRUE;
}

static void on_title(WebKitWebView *v, GParamSpec *p, gpointer _) {
    (void)p;
    const char *t = webkit_web_view_get_title(v);
    gtk_window_set_title(window, t && *t ? t : "cl");
}

// Saved on close and after each page load, so a crash reopens the same page.
static void save_state(void) {
    GtkWindow *w = window;
    GKeyFile *kf = g_key_file_new();
    const char *uri = webkit_web_view_get_uri(view);
    if (uri && same_origin(uri)) g_key_file_set_string(kf, "window", "url", uri);
    int width, height;
    gtk_window_get_default_size(w, &width, &height);
    g_key_file_set_integer(kf, "window", "width", width);
    g_key_file_set_integer(kf, "window", "height", height);
    g_key_file_set_boolean(kf, "window", "maximized", gtk_window_is_maximized(w));
    g_key_file_set_double(kf, "window", "zoom", webkit_web_view_get_zoom_level(view));
    char *path = state_path();
    g_key_file_save_to_file(kf, path, NULL);
    g_free(path);
    g_key_file_unref(kf);
}

static gboolean on_close(GtkWindow *w, gpointer _) {
    (void)w;
    save_state();
    return FALSE;
}

static void on_load(WebKitWebView *v, WebKitLoadEvent e, gpointer _) {
    (void)v;
    if (e == WEBKIT_LOAD_FINISHED) save_state();
}

static gboolean act_reload(GtkWidget *w, GVariant *args, gpointer _) {
    (void)w, (void)args;
    webkit_web_view_reload(view);
    return TRUE;
}

static gboolean act_zoom(GtkWidget *w, GVariant *args, gpointer data) {
    (void)w, (void)args;
    int dir = GPOINTER_TO_INT(data);
    double z = dir == 0 ? 1.0 : webkit_web_view_get_zoom_level(view) * (dir > 0 ? 1.1 : 1 / 1.1);
    webkit_web_view_set_zoom_level(view, CLAMP(z, 0.3, 4.0));
    return TRUE;
}

static gboolean act_inspect(GtkWidget *w, GVariant *args, gpointer _) {
    (void)w, (void)args;
    webkit_web_inspector_show(webkit_web_view_get_inspector(view));
    return TRUE;
}

static void add_key(GtkShortcutController *c, const char *accel, GtkShortcutFunc f, int data) {
    gtk_shortcut_controller_add_shortcut(c, gtk_shortcut_new(gtk_shortcut_trigger_parse_string(accel),
                                                             gtk_callback_action_new(f, GINT_TO_POINTER(data), NULL)));
}

static void activate(GtkApplication *app, gpointer _) {
    if (window) {
        gtk_window_present(window);
        return;
    }
    GKeyFile *kf = g_key_file_new();
    char *path = state_path();
    gboolean have_state = g_key_file_load_from_file(kf, path, G_KEY_FILE_NONE, NULL);
    g_free(path);

    char *cookies = g_build_filename(data_dir, "cookies.sqlite", NULL);
    char *cache = g_build_filename(data_dir, "cache", NULL);
    WebKitNetworkSession *session = webkit_network_session_new(data_dir, cache);
    webkit_cookie_manager_set_persistent_storage(webkit_network_session_get_cookie_manager(session), cookies,
                                                 WEBKIT_COOKIE_PERSISTENT_STORAGE_SQLITE);
    g_free(cookies);
    g_free(cache);

    view = WEBKIT_WEB_VIEW(g_object_new(WEBKIT_TYPE_WEB_VIEW, "network-session", session, NULL));
    WebKitSettings *s = webkit_web_view_get_settings(view);
    webkit_settings_set_javascript_can_access_clipboard(s, TRUE);
    webkit_settings_set_enable_developer_extras(s, TRUE);
    g_signal_connect(view, "decide-policy", G_CALLBACK(on_decide_policy), NULL);
    g_signal_connect(view, "notify::title", G_CALLBACK(on_title), NULL);
    g_signal_connect(view, "load-changed", G_CALLBACK(on_load), NULL);

    window = GTK_WINDOW(gtk_application_window_new(app));
    gtk_window_set_title(window, "cl");
    gtk_window_set_icon_name(window, APP_ID);
    gtk_window_set_child(window, GTK_WIDGET(view));
    int width = have_state ? g_key_file_get_integer(kf, "window", "width", NULL) : 0;
    int height = have_state ? g_key_file_get_integer(kf, "window", "height", NULL) : 0;
    gtk_window_set_default_size(window, width > 200 ? width : 1280, height > 150 ? height : 820);
    if (have_state && g_key_file_get_boolean(kf, "window", "maximized", NULL)) gtk_window_maximize(window);
    double zoom = have_state ? g_key_file_get_double(kf, "window", "zoom", NULL) : 0;
    if (zoom > 0) webkit_web_view_set_zoom_level(view, zoom);
    g_signal_connect(window, "close-request", G_CALLBACK(on_close), NULL);

    // Capture phase: these run before the page sees the key. Everything else
    // goes to the page.
    GtkEventController *keys = gtk_shortcut_controller_new();
    gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE);
    GtkShortcutController *kc = GTK_SHORTCUT_CONTROLLER(keys);
    add_key(kc, "<Control><Shift>r", act_reload, 0);
    add_key(kc, "<Control><Shift>plus", act_zoom, 1);
    add_key(kc, "<Control><Shift>equal", act_zoom, 1);
    add_key(kc, "<Control><Shift>underscore", act_zoom, -1);
    add_key(kc, "<Control><Shift>minus", act_zoom, -1);
    add_key(kc, "<Control><Shift>parenright", act_zoom, 0);
    add_key(kc, "<Control><Shift>0", act_zoom, 0);
    add_key(kc, "<Control><Shift>i", act_inspect, 0);
    gtk_widget_add_controller(GTK_WIDGET(window), keys);

    // Reopen the last page, if it was on this server.
    char *last = have_state ? g_key_file_get_string(kf, "window", "url", NULL) : NULL;
    webkit_web_view_load_uri(view, last && same_origin(last) ? last : start_url);
    g_free(last);
    g_key_file_unref(kf);

    gtk_window_present(window);
    gtk_widget_grab_focus(GTK_WIDGET(view));
}

int main(int argc, char **argv) {
    if (argc != 3) {
        g_printerr("usage: cl-window <url> <data dir> (run `cl window` instead)\n");
        return 2;
    }
    start_url = argv[1];
    data_dir = argv[2];
    origin = origin_of(start_url);
    g_mkdir_with_parents(data_dir, 0700);
    g_set_prgname(APP_ID);
    g_set_application_name("cl");
    gtk_window_set_default_icon_name(APP_ID);
    GtkApplication *app = gtk_application_new(APP_ID, G_APPLICATION_DEFAULT_FLAGS);
    g_signal_connect(app, "activate", G_CALLBACK(activate), NULL);
    // The arguments are ours, not GApplication's.
    int status = g_application_run(G_APPLICATION(app), 1, argv);
    g_object_unref(app);
    return status;
}
