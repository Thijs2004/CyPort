/* On-screen controller layout (PadLayout.c). Points, origin top-left. */
#ifndef MS_PAD_LAYOUT_H
#define MS_PAD_LAYOUT_H

enum {
    MS_PAD_A, MS_PAD_B, MS_PAD_X, MS_PAD_Y, MS_PAD_LB, MS_PAD_LT, MS_PAD_RB, MS_PAD_RT, MS_PAD_L3, MS_PAD_R3,
    MS_PAD_UP, MS_PAD_DOWN, MS_PAD_LEFT, MS_PAD_RIGHT, MS_PAD_VIEW, MS_PAD_MENU, MS_PAD_TOGGLE,
    MS_PAD_ESC, MS_PAD_SPACE, MS_PAD_ENTER,
    MS_PAD_STICK,                       /* the left stick's home (drawn base); r = its radius */
    MS_PAD_COUNT
};
typedef struct { double x, y, r; } MSPadPos;                     /* centre and radius; x = -1000: not placed */
typedef struct { double x, y, w, h; } MSRect;
typedef struct {
    double w, h;                              /* the view (= the phone's screen) */
    double top, left, bottom, right;          /* safe-area insets */
    double gameW, gameH;                      /* the game's picture size (points, as the game was told) */
    int duoInner;                             /* an unfolded iPhone Duo: keep clear of the status pill (top-right) */
    double cutX0, cutY0, cutX1, cutY1;        /* a camera cutout to keep clear when it isn't in the insets (0: none) */
} MSPadScreen;
/* the game's HUD, as fractions of its picture (measured on iPhone Duo screenshots, default HUD) */
typedef struct { const char *name; double x0, y0, x1, y1; } MSPadZone;
extern const MSPadZone MSPadHUD[]; extern const int MSPadHUDCount;
#define MS_PAD_HUD_SLACK 4                    /* a control may reach this far (points) into a HUD zone */

MSRect MSPadPicture(MSPadScreen s);           /* where the game's picture goes (scaled to fit) */
void MSPadLayout(MSPadScreen s, MSPadPos *p); /* p: MS_PAD_COUNT entries */
double MSPadCircleRect(MSPadPos p, double x0, double y0, double x1, double y1);   /* > 0: overlap depth */
void MSPadPill(MSPadScreen s, double *x0, double *y0, double *x1, double *y1);      /* Duo status pill zone */

#endif
