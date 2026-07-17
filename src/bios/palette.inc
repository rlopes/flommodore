; palette.inc -- Flommodore default palette (Phase 6 6.6), 256 x RGB.
;
; GENERATED data, committed as source (decision bf). Layout per spec:
;   0        black          1        white
;   2-15     the classic 14-colour home computer set (decision bg:
;            C64 palette, Pepto-style RGB, minus black/white)
;   16-231   6x6x6 RGB cube, xterm levels 0/95/135/175/215/255
;   232-255  24-step grey ramp 8..238 (xterm convention)

    ORG $FF800

    DB $00, $00, $00   ;   0 black
    DB $FF, $FF, $FF   ;   1 white
    DB $68, $37, $2B   ;   2 red
    DB $70, $A4, $B2   ;   3 cyan
    DB $6F, $3D, $86   ;   4 purple
    DB $58, $8D, $43   ;   5 green
    DB $35, $28, $79   ;   6 blue
    DB $B8, $C7, $6F   ;   7 yellow
    DB $6F, $4F, $25   ;   8 orange
    DB $43, $39, $00   ;   9 brown
    DB $9A, $67, $59   ;  10 light red
    DB $44, $44, $44   ;  11 dark grey
    DB $6C, $6C, $6C   ;  12 mid grey
    DB $9A, $D2, $84   ;  13 light green
    DB $6C, $5E, $B5   ;  14 light blue
    DB $95, $95, $95   ;  15 light grey
    DB $00, $00, $00, $00, $00, $5F, $00, $00, $87, $00, $00, $AF   ;  16- 19 cube
    DB $00, $00, $D7, $00, $00, $FF, $00, $5F, $00, $00, $5F, $5F   ;  20- 23 cube
    DB $00, $5F, $87, $00, $5F, $AF, $00, $5F, $D7, $00, $5F, $FF   ;  24- 27 cube
    DB $00, $87, $00, $00, $87, $5F, $00, $87, $87, $00, $87, $AF   ;  28- 31 cube
    DB $00, $87, $D7, $00, $87, $FF, $00, $AF, $00, $00, $AF, $5F   ;  32- 35 cube
    DB $00, $AF, $87, $00, $AF, $AF, $00, $AF, $D7, $00, $AF, $FF   ;  36- 39 cube
    DB $00, $D7, $00, $00, $D7, $5F, $00, $D7, $87, $00, $D7, $AF   ;  40- 43 cube
    DB $00, $D7, $D7, $00, $D7, $FF, $00, $FF, $00, $00, $FF, $5F   ;  44- 47 cube
    DB $00, $FF, $87, $00, $FF, $AF, $00, $FF, $D7, $00, $FF, $FF   ;  48- 51 cube
    DB $5F, $00, $00, $5F, $00, $5F, $5F, $00, $87, $5F, $00, $AF   ;  52- 55 cube
    DB $5F, $00, $D7, $5F, $00, $FF, $5F, $5F, $00, $5F, $5F, $5F   ;  56- 59 cube
    DB $5F, $5F, $87, $5F, $5F, $AF, $5F, $5F, $D7, $5F, $5F, $FF   ;  60- 63 cube
    DB $5F, $87, $00, $5F, $87, $5F, $5F, $87, $87, $5F, $87, $AF   ;  64- 67 cube
    DB $5F, $87, $D7, $5F, $87, $FF, $5F, $AF, $00, $5F, $AF, $5F   ;  68- 71 cube
    DB $5F, $AF, $87, $5F, $AF, $AF, $5F, $AF, $D7, $5F, $AF, $FF   ;  72- 75 cube
    DB $5F, $D7, $00, $5F, $D7, $5F, $5F, $D7, $87, $5F, $D7, $AF   ;  76- 79 cube
    DB $5F, $D7, $D7, $5F, $D7, $FF, $5F, $FF, $00, $5F, $FF, $5F   ;  80- 83 cube
    DB $5F, $FF, $87, $5F, $FF, $AF, $5F, $FF, $D7, $5F, $FF, $FF   ;  84- 87 cube
    DB $87, $00, $00, $87, $00, $5F, $87, $00, $87, $87, $00, $AF   ;  88- 91 cube
    DB $87, $00, $D7, $87, $00, $FF, $87, $5F, $00, $87, $5F, $5F   ;  92- 95 cube
    DB $87, $5F, $87, $87, $5F, $AF, $87, $5F, $D7, $87, $5F, $FF   ;  96- 99 cube
    DB $87, $87, $00, $87, $87, $5F, $87, $87, $87, $87, $87, $AF   ; 100-103 cube
    DB $87, $87, $D7, $87, $87, $FF, $87, $AF, $00, $87, $AF, $5F   ; 104-107 cube
    DB $87, $AF, $87, $87, $AF, $AF, $87, $AF, $D7, $87, $AF, $FF   ; 108-111 cube
    DB $87, $D7, $00, $87, $D7, $5F, $87, $D7, $87, $87, $D7, $AF   ; 112-115 cube
    DB $87, $D7, $D7, $87, $D7, $FF, $87, $FF, $00, $87, $FF, $5F   ; 116-119 cube
    DB $87, $FF, $87, $87, $FF, $AF, $87, $FF, $D7, $87, $FF, $FF   ; 120-123 cube
    DB $AF, $00, $00, $AF, $00, $5F, $AF, $00, $87, $AF, $00, $AF   ; 124-127 cube
    DB $AF, $00, $D7, $AF, $00, $FF, $AF, $5F, $00, $AF, $5F, $5F   ; 128-131 cube
    DB $AF, $5F, $87, $AF, $5F, $AF, $AF, $5F, $D7, $AF, $5F, $FF   ; 132-135 cube
    DB $AF, $87, $00, $AF, $87, $5F, $AF, $87, $87, $AF, $87, $AF   ; 136-139 cube
    DB $AF, $87, $D7, $AF, $87, $FF, $AF, $AF, $00, $AF, $AF, $5F   ; 140-143 cube
    DB $AF, $AF, $87, $AF, $AF, $AF, $AF, $AF, $D7, $AF, $AF, $FF   ; 144-147 cube
    DB $AF, $D7, $00, $AF, $D7, $5F, $AF, $D7, $87, $AF, $D7, $AF   ; 148-151 cube
    DB $AF, $D7, $D7, $AF, $D7, $FF, $AF, $FF, $00, $AF, $FF, $5F   ; 152-155 cube
    DB $AF, $FF, $87, $AF, $FF, $AF, $AF, $FF, $D7, $AF, $FF, $FF   ; 156-159 cube
    DB $D7, $00, $00, $D7, $00, $5F, $D7, $00, $87, $D7, $00, $AF   ; 160-163 cube
    DB $D7, $00, $D7, $D7, $00, $FF, $D7, $5F, $00, $D7, $5F, $5F   ; 164-167 cube
    DB $D7, $5F, $87, $D7, $5F, $AF, $D7, $5F, $D7, $D7, $5F, $FF   ; 168-171 cube
    DB $D7, $87, $00, $D7, $87, $5F, $D7, $87, $87, $D7, $87, $AF   ; 172-175 cube
    DB $D7, $87, $D7, $D7, $87, $FF, $D7, $AF, $00, $D7, $AF, $5F   ; 176-179 cube
    DB $D7, $AF, $87, $D7, $AF, $AF, $D7, $AF, $D7, $D7, $AF, $FF   ; 180-183 cube
    DB $D7, $D7, $00, $D7, $D7, $5F, $D7, $D7, $87, $D7, $D7, $AF   ; 184-187 cube
    DB $D7, $D7, $D7, $D7, $D7, $FF, $D7, $FF, $00, $D7, $FF, $5F   ; 188-191 cube
    DB $D7, $FF, $87, $D7, $FF, $AF, $D7, $FF, $D7, $D7, $FF, $FF   ; 192-195 cube
    DB $FF, $00, $00, $FF, $00, $5F, $FF, $00, $87, $FF, $00, $AF   ; 196-199 cube
    DB $FF, $00, $D7, $FF, $00, $FF, $FF, $5F, $00, $FF, $5F, $5F   ; 200-203 cube
    DB $FF, $5F, $87, $FF, $5F, $AF, $FF, $5F, $D7, $FF, $5F, $FF   ; 204-207 cube
    DB $FF, $87, $00, $FF, $87, $5F, $FF, $87, $87, $FF, $87, $AF   ; 208-211 cube
    DB $FF, $87, $D7, $FF, $87, $FF, $FF, $AF, $00, $FF, $AF, $5F   ; 212-215 cube
    DB $FF, $AF, $87, $FF, $AF, $AF, $FF, $AF, $D7, $FF, $AF, $FF   ; 216-219 cube
    DB $FF, $D7, $00, $FF, $D7, $5F, $FF, $D7, $87, $FF, $D7, $AF   ; 220-223 cube
    DB $FF, $D7, $D7, $FF, $D7, $FF, $FF, $FF, $00, $FF, $FF, $5F   ; 224-227 cube
    DB $FF, $FF, $87, $FF, $FF, $AF, $FF, $FF, $D7, $FF, $FF, $FF   ; 228-231 cube
    DB $08, $08, $08, $12, $12, $12, $1C, $1C, $1C, $26, $26, $26   ; 232-235 grey
    DB $30, $30, $30, $3A, $3A, $3A, $44, $44, $44, $4E, $4E, $4E   ; 236-239 grey
    DB $58, $58, $58, $62, $62, $62, $6C, $6C, $6C, $76, $76, $76   ; 240-243 grey
    DB $80, $80, $80, $8A, $8A, $8A, $94, $94, $94, $9E, $9E, $9E   ; 244-247 grey
    DB $A8, $A8, $A8, $B2, $B2, $B2, $BC, $BC, $BC, $C6, $C6, $C6   ; 248-251 grey
    DB $D0, $D0, $D0, $DA, $DA, $DA, $E4, $E4, $E4, $EE, $EE, $EE   ; 252-255 grey
