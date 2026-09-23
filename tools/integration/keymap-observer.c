/* Public Wayland client used by the nested-session regression.
 *
 * WAYLAND_DEBUG supplies the wire trace.  This listener adds the one fact the
 * generic logger cannot: an identity of every wl_keyboard keymap fd's bytes.
 * It also resolves received keys with the advertised modifier/group state.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>
#include "xdg-shell-client-protocol.h"

struct app {
    struct wl_display *display;
    struct wl_compositor *compositor;
    struct wl_shm *shm;
    struct wl_seat *seat;
    struct wl_keyboard *keyboard;
    struct xdg_wm_base *wm_base;
    struct wl_surface *surface;
    struct xdg_surface *xdg_surface;
    struct xdg_toplevel *toplevel;
    struct xkb_context *xkb_context;
    struct xkb_keymap *keymap;
    struct xkb_state *state;
    unsigned keymap_events;
};

static uint64_t fnv1a(const unsigned char *bytes, size_t size) {
    uint64_t hash = UINT64_C(1469598103934665603);
    for (size_t i = 0; i < size; i++) {
        hash ^= bytes[i];
        hash *= UINT64_C(1099511628211);
    }
    return hash;
}

static void keyboard_keymap(void *data, struct wl_keyboard *keyboard,
                            uint32_t format, int fd, uint32_t size) {
    (void)keyboard;
    struct app *app = data;
    if (format != WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) {
        fprintf(stderr, "KEYMAP unsupported-format=%u\n", format);
        close(fd);
        return;
    }
    char *text = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (text == MAP_FAILED) {
        fprintf(stderr, "KEYMAP mmap-error=%s\n", strerror(errno));
        return;
    }
    uint64_t identity = fnv1a((const unsigned char *)text, size);
    app->keymap_events++;
    printf("KEYMAP event=%u bytes=%u id=%016llx catalogue=%d\n",
           app->keymap_events, size, (unsigned long long)identity,
           memmem(text, size, "OSK_RESERVED", strlen("OSK_RESERVED")) != NULL);
    fflush(stdout);

    struct xkb_keymap *keymap = xkb_keymap_new_from_string(
        app->xkb_context, text, XKB_KEYMAP_FORMAT_TEXT_V1,
        XKB_KEYMAP_COMPILE_NO_FLAGS);
    munmap(text, size);
    if (!keymap) {
        fprintf(stderr, "KEYMAP xkb compile failed\n");
        return;
    }
    struct xkb_state *state = xkb_state_new(keymap);
    if (!state) {
        xkb_keymap_unref(keymap);
        fprintf(stderr, "KEYMAP xkb state failed\n");
        return;
    }
    if (app->state) xkb_state_unref(app->state);
    if (app->keymap) xkb_keymap_unref(app->keymap);
    app->keymap = keymap;
    app->state = state;
}

static void keyboard_enter(void *data, struct wl_keyboard *keyboard,
                           uint32_t serial, struct wl_surface *surface,
                           struct wl_array *keys) {
    (void)data; (void)keyboard; (void)serial; (void)surface; (void)keys;
    printf("FOCUS enter\n"); fflush(stdout);
}
static void keyboard_leave(void *data, struct wl_keyboard *keyboard,
                           uint32_t serial, struct wl_surface *surface) {
    (void)data; (void)keyboard; (void)serial; (void)surface;
    printf("FOCUS leave\n"); fflush(stdout);
}
static void keyboard_key(void *data, struct wl_keyboard *keyboard,
                         uint32_t serial, uint32_t time, uint32_t key,
                         uint32_t state) {
    (void)keyboard; (void)serial; (void)time;
    struct app *app = data;
    if (!app->state || state != WL_KEYBOARD_KEY_STATE_PRESSED) return;
    char utf8[64] = {0};
    xkb_state_key_get_utf8(app->state, key + 8, utf8, sizeof(utf8));
    printf("KEY evdev=%u group=%u text=%s\n", key,
           xkb_state_serialize_layout(app->state, XKB_STATE_LAYOUT_EFFECTIVE),
           utf8[0] ? utf8 : "-");
    fflush(stdout);
}
static void keyboard_modifiers(void *data, struct wl_keyboard *keyboard,
                               uint32_t serial, uint32_t depressed,
                               uint32_t latched, uint32_t locked,
                               uint32_t group) {
    (void)keyboard; (void)serial;
    struct app *app = data;
    if (app->state)
        xkb_state_update_mask(app->state, depressed, latched, locked, 0, 0, group);
    printf("MODIFIERS group=%u depressed=%u latched=%u locked=%u\n",
           group, depressed, latched, locked);
    fflush(stdout);
}
static void keyboard_repeat(void *data, struct wl_keyboard *keyboard,
                            int32_t rate, int32_t delay) {
    (void)data; (void)keyboard; (void)rate; (void)delay;
}
static const struct wl_keyboard_listener keyboard_listener = {
    keyboard_keymap, keyboard_enter, keyboard_leave, keyboard_key,
    keyboard_modifiers, keyboard_repeat,
};

static void seat_capabilities(void *data, struct wl_seat *seat, uint32_t caps) {
    struct app *app = data;
    if ((caps & WL_SEAT_CAPABILITY_KEYBOARD) && !app->keyboard) {
        app->keyboard = wl_seat_get_keyboard(seat);
        wl_keyboard_add_listener(app->keyboard, &keyboard_listener, app);
    }
}
static void seat_name(void *data, struct wl_seat *seat, const char *name) {
    (void)data; (void)seat; (void)name;
}
static const struct wl_seat_listener seat_listener = {seat_capabilities, seat_name};

static void wm_ping(void *data, struct xdg_wm_base *wm, uint32_t serial) {
    (void)data; xdg_wm_base_pong(wm, serial);
}
static const struct xdg_wm_base_listener wm_listener = {wm_ping};

static void registry_global(void *data, struct wl_registry *registry,
                            uint32_t name, const char *interface,
                            uint32_t version) {
    struct app *app = data;
    if (!strcmp(interface, wl_compositor_interface.name))
        app->compositor = wl_registry_bind(registry, name,
            &wl_compositor_interface, version < 4 ? version : 4);
    else if (!strcmp(interface, wl_shm_interface.name))
        app->shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    else if (!strcmp(interface, wl_seat_interface.name)) {
        app->seat = wl_registry_bind(registry, name, &wl_seat_interface,
                                     version < 7 ? version : 7);
        wl_seat_add_listener(app->seat, &seat_listener, app);
    } else if (!strcmp(interface, xdg_wm_base_interface.name)) {
        app->wm_base = wl_registry_bind(registry, name, &xdg_wm_base_interface, 1);
        xdg_wm_base_add_listener(app->wm_base, &wm_listener, app);
    }
}
static void registry_remove(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data; (void)registry; (void)name;
}
static const struct wl_registry_listener registry_listener = {
    registry_global, registry_remove,
};

static struct wl_buffer *make_buffer(struct app *app) {
    char name[] = "/tmp/osk-keymap-observer.XXXXXX";
    int fd = mkstemp(name);
    if (fd < 0) return NULL;
    unlink(name);
    if (ftruncate(fd, 4) < 0) { close(fd); return NULL; }
    uint32_t *pixel = mmap(NULL, 4, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (pixel == MAP_FAILED) { close(fd); return NULL; }
    *pixel = UINT32_C(0xff202020);
    struct wl_shm_pool *pool = wl_shm_create_pool(app->shm, fd, 4);
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(
        pool, 0, 1, 1, 4, WL_SHM_FORMAT_XRGB8888);
    wl_shm_pool_destroy(pool);
    munmap(pixel, 4);
    close(fd);
    return buffer;
}

static void surface_configure(void *data, struct xdg_surface *surface,
                              uint32_t serial) {
    struct app *app = data;
    xdg_surface_ack_configure(surface, serial);
    struct wl_buffer *buffer = make_buffer(app);
    if (!buffer) { fprintf(stderr, "cannot make shm buffer\n"); exit(2); }
    wl_surface_attach(app->surface, buffer, 0, 0);
    wl_surface_damage(app->surface, 0, 0, 1, 1);
    wl_surface_commit(app->surface);
    printf("READY\n"); fflush(stdout);
}
static const struct xdg_surface_listener surface_listener = {surface_configure};

int main(void) {
    struct app app = {0};
    app.xkb_context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    app.display = wl_display_connect(NULL);
    if (!app.display || !app.xkb_context) return 2;
    struct wl_registry *registry = wl_display_get_registry(app.display);
    wl_registry_add_listener(registry, &registry_listener, &app);
    wl_display_roundtrip(app.display);
    if (!app.compositor || !app.shm || !app.seat || !app.wm_base) return 3;
    app.surface = wl_compositor_create_surface(app.compositor);
    app.xdg_surface = xdg_wm_base_get_xdg_surface(app.wm_base, app.surface);
    xdg_surface_add_listener(app.xdg_surface, &surface_listener, &app);
    app.toplevel = xdg_surface_get_toplevel(app.xdg_surface);
    xdg_toplevel_set_title(app.toplevel, "OSK keymap observer");
    xdg_toplevel_set_app_id(app.toplevel, "osk-keymap-observer");
    wl_surface_commit(app.surface);
    while (wl_display_dispatch(app.display) >= 0) {}
    return 0;
}
