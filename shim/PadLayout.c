/* On-screen controller layout and where the game picture goes on the phone's screen. Plain C so it can be tested on a
 * Mac (tools/test_pad_layout.sh). All values in UIKit points, origin top-left.
 *
 * Landscape: the picture fills the screen, so the controls keep out of the corners where the game draws its HUD
 * (minimap + quest top-right, health / phone calls top-left, quick items bottom-left, prompts / weapon bottom-right,
 * subtitles bottom-centre) and out of the system's areas (safe-area insets: camera, home bar; on an unfolded iPhone Duo
 * also the status pill in the top-right corner, which the safe area doesn't always include). Shoulder buttons sit just
 * above the stick and the face buttons, where the thumbs already are; the d-pad and the small keys use the top band
 * between the health bar and the minimap.
 * Portrait (an unfolded iPhone Duo held upright): the picture goes to the top, under the camera / status strip, and the
 * whole controller sits in the space below it, laid out like a gamepad: shoulders on top, stick + d-pad bottom-left,
 * face buttons bottom-right, L3 in the bottom-left corner.
 * Each group starts at its usual place and moves the least distance (inward / upward) that keeps it clear.
 * Landscape: two mirrored thumb clusters, as drawn on iPhone Duo screenshots - left the stick with LT · LB · L3 in an
 * arc above it, right a compact X/Y/B/A diamond with R3 · RB · RT in an arc above it, both at the same height, low where
 * the thumbs rest. A big screen (the Duo unfolded, iPads) and a small one (the Duo folded, other iPhones; a smaller
 * cluster closer to the edges). The top band keeps the d-pad and the small keys. */
#include "PadLayout.h"
#include <math.h>

const MSPadZone MSPadHUD[] = {
    { "minimap",       0.84,  0.00, 1.00,  0.23 },
    { "quest",         0.79,  0.24, 1.00,  0.31 },
    { "health",        0.00,  0.00, 0.30,  0.10 },
    { "call portrait", 0.00,  0.11, 0.155, 0.31 },
    { "quick items",   0.00,  0.79, 0.165, 1.00 },
    { "prompts",       0.875, 0.70, 1.00,  0.89 },
    { "weapon / ammo", 0.86,  0.90, 1.00,  1.00 },
    { "stance",        0.94,  0.92, 1.00,  1.00 },
    /* not kept clear: the dialogue subtitles (bottom centre, they come and go) - the stick and the face buttons sit
       where the thumbs rest, which may cover the ends of a long line */
};
const int MSPadHUDCount = sizeof MSPadHUD / sizeof *MSPadHUD;

static double maxd(double a, double b) { return a > b ? a : b; }
static double mind(double a, double b) { return a < b ? a : b; }

double MSPadCircleRect(MSPadPos p, double x0, double y0, double x1, double y1) {
    double cx = maxd(x0, mind(p.x, x1)), cy = maxd(y0, mind(p.y, y1));
    return p.r - hypot(p.x - cx, p.y - cy);
}
void MSPadPill(MSPadScreen s, double *x0, double *y0, double *x1, double *y1) { *x0 = s.w - 95; *y0 = 0; *x1 = s.w; *y1 = 108; }

MSRect MSPadPicture(MSPadScreen s) {
    MSRect r = { 0, 0, s.w, s.h };
    if (!(s.gameW > 0 && s.gameH > 0 && s.w > 0 && s.h > 0)) return r;
    double k = mind(s.w / s.gameW, s.h / s.gameH);
    r.w = s.gameW * k; r.h = s.gameH * k; r.x = (s.w - r.w) / 2;
    if (s.h > s.w) {                                   /* portrait: at the top, below the camera / status strip */
        double top = s.top;
        if (s.duoInner) { double x0, y0, x1, y1; MSPadPill(s, &x0, &y0, &x1, &y1); top = maxd(top, y1); }   /* minimap clear of the pill */
        if (s.cutX1 > s.cutX0 && s.cutY0 < s.h / 4) top = maxd(top, s.cutY1);                             /* ... and of a camera */
        r.y = mind(top, s.h - r.h);
    }
    else r.y = (s.h - r.h) / 2;
    return r;
}

typedef struct { MSPadScreen s; MSRect pic; MSPadPos *p; int placed[MS_PAD_COUNT]; int hud; } Ctx;

/* how badly a control at q would sit: 0 = fine */
static double bad(Ctx *c, int self, MSPadPos q) {
    MSPadScreen s = c->s; double b = 0;
    b += maxd(0, s.left - (q.x - q.r)) + maxd(0, (q.x + q.r) - (s.w - s.right)) + maxd(0, s.top - (q.y - q.r)) + maxd(0, (q.y + q.r) - (s.h - s.bottom));
    for (int j = 0; j < MS_PAD_COUNT; j++) {
        if (!c->placed[j] || j == self) continue;
        b += maxd(0, c->p[j].r + q.r + 6 - hypot(q.x - c->p[j].x, q.y - c->p[j].y));
    }
    double x0, y0, x1, y1;
    if (s.duoInner) { MSPadPill(s, &x0, &y0, &x1, &y1); b += maxd(0, MSPadCircleRect(q, x0, y0, x1, y1)); }
    if (s.bottom > 0) b += maxd(0, MSPadCircleRect(q, s.w / 2 - 75, s.h - 14, s.w / 2 + 75, s.h));
    if (s.cutX1 > s.cutX0) b += maxd(0, MSPadCircleRect(q, s.cutX0, s.cutY0, s.cutX1, s.cutY1));
    if (c->hud && self != MS_PAD_STICK)
        for (int z = 0; z < MSPadHUDCount; z++) {
            const MSPadZone *h = &MSPadHUD[z]; MSRect P = c->pic;
            b += maxd(0, MSPadCircleRect(q, P.x + h->x0 * P.w, P.y + h->y0 * P.h, P.x + h->x1 * P.w, P.y + h->y1 * P.h) - MS_PAD_HUD_SLACK);
        }
    return b;
}

/* place n controls (ids, offsets from the anchor, radii) at anchor + the smallest shift along (dirx, diry) that is clear;
   when that direction can't clear them, the opposite one is tried as well */
static void placeGroup(Ctx *c, int n, const int *id, const double *ox, const double *oy, const double *r, double ax, double ay, double dirx, double diry) {
    double bestB = 1e18, bx = 0, by = 0;
    for (int pass = 0; pass < 2 && bestB > 0; pass++, dirx = -dirx, diry = -diry)
        for (int step = 0; step <= 60 && bestB > 0; step++)
            for (int k = 0; k <= step && bestB > 0; k++) {
                double dx = dirx * 5 * k, dy = diry * 5 * (step - k), b = 0;
                for (int i = 0; i < n; i++) { MSPadPos q = { ax + dx + ox[i], ay + dy + oy[i], r[i] }; b += bad(c, id[i], q); }
                if (b < bestB) { bestB = b; bx = dx; by = dy; }
            }
    for (int i = 0; i < n; i++) { c->p[id[i]].x = ax + bx + ox[i]; c->p[id[i]].y = ay + by + oy[i]; c->p[id[i]].r = r[i]; c->placed[id[i]] = 1; }
}
static void place1(Ctx *c, int id, double x, double y, double r, double dirx, double diry) {
    double z = 0; placeGroup(c, 1, &id, &z, &z, &r, x, y, dirx, diry);
}
static const int FACE_ID[] = { MS_PAD_Y, MS_PAD_A, MS_PAD_X, MS_PAD_B };
static const int DPAD_ID[] = { MS_PAD_UP, MS_PAD_DOWN, MS_PAD_LEFT, MS_PAD_RIGHT };
static const int KEY_ID[] = { MS_PAD_ESC, MS_PAD_VIEW, MS_PAD_TOGGLE, MS_PAD_MENU, MS_PAD_SPACE, MS_PAD_ENTER };
static const double KEY_R[] = { 19, 17, 17, 17, 21, 21 };
static double rk(double r, double k) { return maxd(r * k, mind(r, 13)); }     /* scaled radius, never under 13 pt */
static void faces(Ctx *c, double x, double y, double k, double dirx, double diry) {
    double r = rk(27, k), d = maxd(50 * k, (2 * r + 8) / sqrt(2)), ox[] = { 0, 0, -d, d }, oy[] = { -d, d, 0, 0 }, rr[] = { r, r, r, r };
    placeGroup(c, 4, FACE_ID, ox, oy, rr, x, y, dirx, diry);
}
static void dpad(Ctx *c, double x, double y, double k, double dirx, double diry) {
    double r = rk(16, k), d = maxd(32 * k, (2 * r + 8) / sqrt(2)), ox[] = { 0, 0, -d, d }, oy[] = { -d, d, 0, 0 }, rr[] = { r, r, r, r };
    placeGroup(c, 4, DPAD_ID, ox, oy, rr, x, y, dirx, diry);
}

/* the small keys centred in x0..x1 at y: one row, or two (Esc ⧉ 🎮 ≡ / Space Enter) when one doesn't fit */
static int keys(Ctx *c, double x0, double x1, double y, double k, double dirx, double diry) {
    double ox[6], oy[6], R[6], w = 0, gap = 12 * k;
    for (int i = 0; i < 6; i++) { R[i] = rk(KEY_R[i], k); w += 2 * R[i] + (i ? gap : 0); }
    if (w <= x1 - x0) {
        double x = -w / 2; for (int i = 0; i < 6; i++) { ox[i] = x + R[i]; oy[i] = 0; x += 2 * R[i] + gap; }
        placeGroup(c, 6, KEY_ID, ox, oy, R, (x0 + x1) / 2, y, dirx, diry); return 1;
    }
    double w1 = 0, w2 = 0; for (int i = 0; i < 4; i++) w1 += 2 * R[i] + (i ? gap : 0);
    for (int i = 4; i < 6; i++) w2 += 2 * R[i] + (i > 4 ? gap : 0);
    if (w1 > x1 - x0) return 0;
    double x = -w1 / 2; for (int i = 0; i < 4; i++) { ox[i] = x + R[i]; oy[i] = 0; x += 2 * R[i] + gap; }
    x = -w2 / 2;        for (int i = 4; i < 6; i++) { ox[i] = x + R[i]; oy[i] = 46 * k; x += 2 * R[i] + gap; }
    placeGroup(c, 6, KEY_ID, ox, oy, R, (x0 + x1) / 2, y, dirx, diry); return 1;
}

void MSPadLayout(MSPadScreen s, MSPadPos *p) {
    Ctx c = { .s = s, .pic = MSPadPicture(s), .p = p };
    for (int i = 0; i < MS_PAD_COUNT; i++) { p[i].x = p[i].y = -1000; p[i].r = 0; }
    double L = maxd(s.left, 16), R = s.w - maxd(s.right, 16), T = maxd(s.top, 8), H = s.h - maxd(s.bottom, 8);
    MSRect pic = c.pic;

    double padTop = pic.y + pic.h + 10;
    if (s.h > s.w && H - padTop >= 140) {                   /* portrait with room under the picture: a gamepad */
        /* sized for the unfolded iPhone Duo (669 pt wide, 328 pt under the picture). Narrower / shorter spaces (the Duo
           folded) get distances scaled across and down separately, buttons no smaller than 60% */
        double kx = mind(1, s.w / 669), ky = mind(1, (H - padTop) / 328), kr = mind(kx, maxd(ky, 0.6));
        double sy = padTop + 36 * ky, cy = H - 140 * ky;
        place1(&c, MS_PAD_STICK, L + 130 * kx, cy, 60 * kr, 0, 0);
        faces(&c, R - 120 * kx, cy, kr, -1, 0);
        place1(&c, MS_PAD_LT, L + 40 * kx, sy, rk(30, kr), 0, 1);   place1(&c, MS_PAD_LB, L + 112 * kx, sy - 4 * ky, rk(24, kr), 0, 1);
        place1(&c, MS_PAD_RT, R - 40 * kx, sy, rk(30, kr), 0, 1);   place1(&c, MS_PAD_RB, R - 112 * kx, sy - 4 * ky, rk(24, kr), 0, 1);
        double kxk = (112 + 24 + 14) * kx;
        if (!keys(&c, L + kxk, R - kxk, sy - 4 * ky, kr, 0, 1)) keys(&c, L, R, sy + 56 * ky, kr, 0, 1);
        double dx = s.w * 0.43, dy = H - 66 * ky;          /* d-pad below-right of the stick, as on an Xbox pad */
        dpad(&c, dx, dy, kr, 0, -1);
        place1(&c, MS_PAD_R3, s.w - dx, dy, rk(20, kr), 0, -1);
        place1(&c, MS_PAD_L3, L + 44 * kx, H - 32 * ky, rk(20, kr), 1, 0);
        return;
    }

    /* landscape: the two thumb clusters (right first; the left one then gets the same height), then the top band */
    c.hud = 1;
    double k = mind(1, mind(s.w / 951, s.h / 669)); if (k < 0.62) k = 0.62;
    int small = s.h < 520;
    double g = small ? 0.82 : 1;                            /* cluster size */
    double stickR = small ? 47 : 60, faceD = 36 * (small ? 0.85 : 1), faceR = 22 * g;
    double edge = small ? 152 : 221, cy = H - stickR;
    /* arc above a cluster, mirrored for the right hand: outer (trigger), middle (bumper), inner (L3 / R3) */
    double ang[3] = { 50, 20, -25 }, rad[3] = { 120 * g, 106 * g, 106 * g }, br[3] = { 30 * g, 25 * g, 21 * g };
    const double PI = 3.14159265358979;
    {
        int id[7] = { MS_PAD_Y, MS_PAD_A, MS_PAD_X, MS_PAD_B, MS_PAD_RT, MS_PAD_RB, MS_PAD_R3 };
        double ox[7] = { 0, 0, -faceD, faceD }, oy[7] = { -faceD, faceD, 0, 0 }, r[7] = { faceR, faceR, faceR, faceR };
        for (int i = 0; i < 3; i++) { ox[4 + i] = rad[i] * sin(ang[i] * PI / 180); oy[4 + i] = -rad[i] * cos(ang[i] * PI / 180); r[4 + i] = br[i]; }
        placeGroup(&c, 7, id, ox, oy, r, R - edge, cy, -1, -1);
    }
    double dy = p[MS_PAD_X].y - cy;                         /* the right cluster's shift up, if it had to move */
    {
        int id[4] = { MS_PAD_STICK, MS_PAD_LT, MS_PAD_LB, MS_PAD_L3 };
        double ox[4] = { 0 }, oy[4] = { 0 }, r[4] = { stickR };
        for (int i = 0; i < 3; i++) { ox[1 + i] = -rad[i] * sin(ang[i] * PI / 180); oy[1 + i] = -rad[i] * cos(ang[i] * PI / 180); r[1 + i] = br[i]; }
        placeGroup(&c, 4, id, ox, oy, r, L + edge, cy + dy, 1, 0);
    }
    /* top band: right of the health bar / call portrait (left 30% of the picture), left of the minimap (right 16%) */
    double bandL = maxd(L, pic.x + 0.30 * pic.w), bandR = mind(R, pic.x + 0.84 * pic.w) - 12 * k;
    if (s.duoInner) bandR = mind(bandR, s.w - 95 - 12);
    double dxc = bandL + 48 * k;
    dpad(&c, dxc, T + 54 * k, k, 1, 0);
    dxc = p[MS_PAD_UP].x;
    double ky = T + rk(21, k) + 1;
    if (!keys(&c, dxc + 48 * k + 14 * k, bandR, ky, k, 1, 1)) keys(&c, dxc + 48 * k + 14 * k, R, ky, k, 1, 1);
}
