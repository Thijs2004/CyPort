/* Checks the on-screen controller layout (shim/PadLayout.c) on every screen shape CyPort runs on:
 *   tools/test_pad_layout.sh            (builds this with the Mac's clang and runs it; exit 1 on any failure)
 * Fails when two controls overlap, a control leaves the safe area, covers a system area (iPhone Duo status pill,
 * home bar) or covers the game's HUD (zones measured on iPhone Duo screenshots, as fractions of the picture).
 * With --json it prints every layout for tools/pad_preview.py. */
#include "../shim/PadLayout.h"
#include <math.h>
#include <stdio.h>
#include <string.h>

static const char *NAMES[MS_PAD_COUNT] = { "A", "B", "X", "Y", "LB", "LT", "RB", "RT", "L3", "R3", "up", "down", "left", "right",
                                           "view", "menu", "toggle", "Esc", "Space", "Enter", "stick" };
typedef struct { const char *name; MSPadScreen s; } Case;

int main(int argc, char **argv) {
    int json = argc > 1 && !strcmp(argv[1], "--json");
    Case cases[] = {
        { "duo-inner-landscape",          { 951, 669, 0, 0, 34, 0, 951, 669, 1 } },
        { "duo-inner-landscape-top82",    { 951, 669, 82, 0, 34, 0, 951, 669, 1 } },
        { "duo-inner-landscape-right84",  { 951, 669, 0, 0, 34, 84, 951, 669, 1 } },
        { "duo-inner-portrait",           { 669, 951, 82, 0, 34, 0, 951, 669, 1 } },
        /* the Duo's outer screen: the shim passes the camera as its corner (side insets 0), as measured */
        { "duo-outer-landscape-camR",     { 678, 466, 0, 0, 34, 0, 678, 466, 0, 583, 394, 678, 466 } },
        { "duo-outer-landscape-camL",     { 678, 466, 0, 0, 34, 0, 678, 466, 0, 0, 0, 95, 72 } },
        { "duo-outer-insets-only",        { 678, 466, 0, 84, 34, 0, 678, 466, 0 } },
        { "duo-outer-game-from-inner",    { 678, 466, 0, 0, 34, 0, 951, 669, 0, 583, 394, 678, 466 } },
        { "duo-inner-game-from-outer",    { 951, 669, 0, 0, 34, 0, 678, 466, 1 } },
        { "iphone16promax-landscape",     { 932, 430, 0, 62, 21, 62, 932, 430, 0 } },
        { "ipad-pro-13-landscape",        { 1366, 1024, 24, 0, 20, 0, 1366, 1024, 0 } },
    };
    int fails = 0, n = sizeof cases / sizeof *cases;
    if (json) printf("[\n");
    for (int c = 0; c < n; c++) {
        MSPadScreen s = cases[c].s; MSPadPos p[MS_PAD_COUNT]; MSPadLayout(s, p); MSRect pic = MSPadPicture(s);
        int f0 = fails;
        for (int i = 0; i < MS_PAD_COUNT; i++) {
            if (p[i].x == -1000) { printf("FAIL %s: %s not placed\n", cases[c].name, NAMES[i]); fails++; continue; }
            if (p[i].x - p[i].r < s.left || p[i].x + p[i].r > s.w - s.right || p[i].y - p[i].r < s.top || p[i].y + p[i].r > s.h - s.bottom)
                { printf("FAIL %s: %s outside the safe area (%.0f,%.0f r%.0f)\n", cases[c].name, NAMES[i], p[i].x, p[i].y, p[i].r); fails++; }
            for (int j = i + 1; j < MS_PAD_COUNT; j++) {
                double gap = hypot(p[i].x - p[j].x, p[i].y - p[j].y) - p[i].r - p[j].r;
                if (gap < 4) { printf("FAIL %s: %s and %s overlap (gap %.1f)\n", cases[c].name, NAMES[i], NAMES[j], gap); fails++; }
            }
            if (s.duoInner) {                         /* status pill: top-right corner, both orientations */
                double x0, y0, x1, y1; MSPadPill(s, &x0, &y0, &x1, &y1);
                double d = MSPadCircleRect(p[i], x0, y0, x1, y1);
                if (d > 0) { printf("FAIL %s: %s under the status pill (%.1f pt)\n", cases[c].name, NAMES[i], d); fails++; }
            }
            if (s.cutX1 > s.cutX0 && MSPadCircleRect(p[i], s.cutX0, s.cutY0, s.cutX1, s.cutY1) > 0)
                { printf("FAIL %s: %s under the camera\n", cases[c].name, NAMES[i]); fails++; }
            if (s.bottom > 0) {                       /* home bar */
                double d = MSPadCircleRect(p[i], s.w / 2 - 75, s.h - 14, s.w / 2 + 75, s.h);
                if (d > 0) { printf("FAIL %s: %s on the home bar (%.1f pt)\n", cases[c].name, NAMES[i], d); fails++; }
            }
            if (i == MS_PAD_STICK) continue;          /* the stick floats: its drawn base may sit over the HUD a bit */
            for (int z = 0; z < MSPadHUDCount; z++) {
                const MSPadZone *h = &MSPadHUD[z];
                double d = MSPadCircleRect(p[i], pic.x + h->x0 * pic.w, pic.y + h->y0 * pic.h, pic.x + h->x1 * pic.w, pic.y + h->y1 * pic.h);
                if (d > MS_PAD_HUD_SLACK + 0.01) { printf("FAIL %s: %s covers the game's %s (%.1f pt)\n", cases[c].name, NAMES[i], h->name, d); fails++; }
            }
        }
        if (!json) printf("%s %s (%gx%g, picture %.0f,%.0f %.0fx%.0f)\n", fails == f0 ? "ok  " : "BAD ", cases[c].name, s.w, s.h, pic.x, pic.y, pic.w, pic.h);
        else {
            printf(" {\"name\":\"%s\",\"w\":%g,\"h\":%g,\"inset\":[%g,%g,%g,%g],\"cut\":[%g,%g,%g,%g],\"duoInner\":%d,\"pic\":[%g,%g,%g,%g],\"pads\":{",
                   cases[c].name, s.w, s.h, s.top, s.left, s.bottom, s.right, s.cutX0, s.cutY0, s.cutX1, s.cutY1, s.duoInner, pic.x, pic.y, pic.w, pic.h);
            for (int i = 0; i < MS_PAD_COUNT; i++) printf("%s\"%s\":[%g,%g,%g]", i ? "," : "", NAMES[i], p[i].x, p[i].y, p[i].r);
            printf("}}%s\n", c < n - 1 ? "," : "");
        }
    }
    if (json) printf("]\n");
    if (!json) printf("%s: %d failure(s) in %d screens\n", fails ? "FAILED" : "PASSED", fails, n);
    return fails ? 1 : 0;
}
