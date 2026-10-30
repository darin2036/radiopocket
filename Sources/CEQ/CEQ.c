#include "CEQ.h"
#include <stdlib.h>
#include <math.h>
#include <stdatomic.h>
#include <string.h>
#define RP_VIS_RING 8192
#define RP_COMB_MAX 8192
#define RP_AP_MAX 2048
struct RPEQ {
    // Single-producer (audio thread) / single-consumer (UI thread) ring of mono post-EQ,
    // pre-volume samples for the visualizer. Fixed storage; relaxed atomics, release/acquire on the cursor.
    _Atomic float vis[RP_VIS_RING];
    _Atomic uint64_t visWrite;
    _Atomic float target[11];
    _Atomic int enabled;
    _Atomic float volume;
    _Atomic float balance;
    _Atomic int channelCount;
    _Atomic uint64_t frames;
    _Atomic double ratio;
    // Loudness leveler: slow RMS follower steering a gain toward a fixed target, then a soft limiter.
    _Atomic int level;
    _Atomic double levelDb;
    double levelPower, levelGain;
    // Spatial stage: stereo width, headphone crossfeed and a small Freeverb-style room, after the EQ.
    _Atomic int spaceStyle;
    _Atomic float spaceAmount, spaceWidth;
    int spaceApplied;
    double spaceCurrent, widthCurrent, xfLow[2];
    int combLen[4], apLen[2], combPos[2][4], apPos[2];
    float combStore[2][4];
    float comb[2][4][RP_COMB_MAX], allpass[2][2][RP_AP_MAX];
    double rate, b0[10], b1[10], b2[10], a1[10], a2[10];
    double z1[8][10], z2[8][10], current[11];
};
typedef struct { double size, feedback, damp, wet, width, crossfeed; } SpaceStyle;
// Order matches `SpatialStyle` in Swift. Size scales the delay lengths; wet and the width/crossfeed move with the amount slider.
static const SpaceStyle spaceStyles[RP_SPACE_STYLES] = {
    {0,0,0,0,1,0},              // Off
    {.45,.70,.50,.14,1,0},      // Studio
    {.60,.74,.40,.20,1,0},      // Room
    {.80,.78,.30,.26,1.1,0},    // Club
    {1.05,.84,.30,.28,1.1,0},   // Stage
    {1.25,.88,.22,.30,1.15,0},  // Hall
    {1.60,.92,.15,.34,1.2,0},   // Cathedral
    {.55,.76,.35,.12,1.9,0},    // Surround
    {0,0,0,0,1.7,0},            // Wide
    {0,0,0,0,1,.55},            // Headphones
};
static const int combBase[4]={1116,1188,1277,1356}, apBase[2]={556,441};
static void space_reset(RPEQ *e,int style) {
    memset(e->comb,0,sizeof(e->comb)); memset(e->allpass,0,sizeof(e->allpass)); memset(e->combStore,0,sizeof(e->combStore));
    memset(e->combPos,0,sizeof(e->combPos)); memset(e->apPos,0,sizeof(e->apPos)); e->xfLow[0]=e->xfLow[1]=0;
    double scale=fmin(2.2,e->rate/44100)*spaceStyles[style].size;
    for(int i=0;i<4;i++) { int n=(int)(combBase[i]*scale)+1; e->combLen[i]=n<4?4:(n>RP_COMB_MAX-32?RP_COMB_MAX-32:n); }
    for(int i=0;i<2;i++) { int n=(int)(apBase[i]*scale)+1; e->apLen[i]=n<4?4:(n>RP_AP_MAX-1?RP_AP_MAX-1:n); }
    e->spaceApplied=style;
}
void rp_space_set(RPEQ *e,int style,float amount,float width) {
    atomic_store_explicit(&e->spaceStyle,style<0||style>=RP_SPACE_STYLES?0:style,memory_order_relaxed);
    atomic_store_explicit(&e->spaceAmount,fmaxf(0,fminf(1,amount)),memory_order_relaxed);
    atomic_store_explicit(&e->spaceWidth,fmaxf(0,fminf(2,width)),memory_order_relaxed);
}
// Interleaved stereo only: mono and per-channel buffers pass through untouched.
static void space(RPEQ *e,float *data,uint32_t frames,uint32_t channels,uint32_t firstChannel) {
    if(firstChannel!=0 || channels<2 || !frames) return;
    int style=atomic_load_explicit(&e->spaceStyle,memory_order_relaxed);
    double amount=atomic_load_explicit(&e->spaceAmount,memory_order_relaxed), userWidth=atomic_load_explicit(&e->spaceWidth,memory_order_relaxed);
    if(style!=e->spaceApplied) space_reset(e,style);
    const SpaceStyle *st=&spaceStyles[style];
    double blend=1-exp(-(double)frames/(e->rate*.05));
    e->spaceCurrent+=blend*(amount-e->spaceCurrent);
    e->widthCurrent+=blend*(userWidth-e->widthCurrent);
    double a=e->spaceCurrent, width=(1+(st->width-1)*a)*e->widthCurrent;
    if(style==0 && fabs(width-1)<.001) return;
    double wet=st->wet*a, xf=st->crossfeed*a, damp=st->damp, fb=st->feedback;
    double lp=1-exp(-2*M_PI*700/e->rate);
    int reverb=wet>.0005 && st->size>0;
    for(uint32_t f=0;f<frames;f++) {
        float *p=&data[f*channels];
        double l=p[0], r=p[1];
        if(xf>0) {
            e->xfLow[0]+=lp*(l-e->xfLow[0]); e->xfLow[1]+=lp*(r-e->xfLow[1]);
            double nl=(l+xf*e->xfLow[1])/(1+xf*.5), nr=(r+xf*e->xfLow[0])/(1+xf*.5);
            l=nl; r=nr;
        }
        if(fabs(width-1)>.001) { double m=(l+r)*.5, s=(l-r)*.5*width; l=m+s; r=m-s; }
        if(reverb) {
            double in=(l+r)*.5*.25, wl=0, wr=0;
            for(int ch=0;ch<2;ch++) {
                double sum=0;
                for(int c=0;c<4;c++) {
                    int len=e->combLen[c]+(ch?23:0); if(len>RP_COMB_MAX) len=RP_COMB_MAX;
                    int pos=e->combPos[ch][c]; if(pos>=len) pos=0;
                    float out=e->comb[ch][c][pos];
                    e->combStore[ch][c]=(float)(out*(1-damp)+e->combStore[ch][c]*damp);
                    e->comb[ch][c][pos]=(float)(in+e->combStore[ch][c]*fb);
                    e->combPos[ch][c]=pos+1;
                    sum+=out;
                }
                for(int k=0;k<2;k++) {
                    int pos=e->apPos[k];
                    float buffered=e->allpass[ch][k][pos];
                    float out=(float)(-sum+buffered);
                    e->allpass[ch][k][pos]=(float)(sum+buffered*.5);
                    sum=out;
                }
                if(ch) wr=sum; else wl=sum;
            }
            for(int k=0;k<2;k++) e->apPos[k]=(e->apPos[k]+1)%e->apLen[k];
            l+=wl*wet*2; r+=wr*wet*2;
        }
        if(!isfinite(l)) l=0;
        if(!isfinite(r)) r=0;
        p[0]=(float)fmax(-1,fmin(1,l)); p[1]=(float)fmax(-1,fmin(1,r));
    }
}
static const double frequencies[10] = {60,170,310,600,1000,3000,6000,12000,14000,16000};
RPEQ *rp_eq_create(void) {
    RPEQ *e=calloc(1,sizeof(RPEQ));
    if(e) { e->rate=44100; atomic_store(&e->volume,1); atomic_store(&e->ratio,1); e->levelGain=1; atomic_store(&e->spaceWidth,1); e->widthCurrent=1; }
    return e;
}
void rp_eq_destroy(RPEQ *e) { free(e); }
void rp_eq_set(RPEQ *e, int enabled, float preamp, const float *bands) {
    atomic_store_explicit(&e->target[0],fmaxf(-12,fminf(12,preamp)),memory_order_relaxed);
    for(int i=0;i<10;i++) atomic_store_explicit(&e->target[i+1],fmaxf(-12,fminf(12,bands[i])),memory_order_relaxed);
    atomic_store_explicit(&e->enabled,enabled,memory_order_relaxed);
}
void rp_eq_volume(RPEQ *e, float volume) { atomic_store_explicit(&e->volume,fmaxf(0,fminf(1,volume)),memory_order_relaxed); }
void rp_eq_balance(RPEQ *e, float balance) { atomic_store_explicit(&e->balance,fmaxf(-1,fminf(1,balance)),memory_order_relaxed); }
void rp_eq_channels(RPEQ *e, uint32_t channels) { atomic_store_explicit(&e->channelCount,(int)channels,memory_order_relaxed); }
void rp_level_set(RPEQ *e, int enabled) { if(e) atomic_store_explicit(&e->level,enabled,memory_order_relaxed); }
double rp_level_db(RPEQ *e) { return e ? atomic_load_explicit(&e->levelDb,memory_order_relaxed) : 0; }
#define LEVEL_TARGET_DB (-18.0)
#define LEVEL_MAX_BOOST_DB 10.0
#define LEVEL_MAX_CUT_DB (-12.0)
// Applies volume and, when enabled, the leveler to one buffer. Runs after the EQ, before the output.
static void finish(RPEQ *e,float *data,uint32_t frames,uint32_t channels,uint32_t firstChannel,float volume) {
    // Balance only turns down the far side, as Winamp's does: left is channel 0, right is channel 1. A mono stream is panned by the output instead.
    const float balance=atomic_load_explicit(&e->balance,memory_order_relaxed);
    const int declared=atomic_load_explicit(&e->channelCount,memory_order_relaxed);
    const uint32_t total=declared>0?(uint32_t)declared:firstChannel+channels;
    float vg[8];
    for(uint32_t c=0;c<channels && c<8;c++) {
        float side=1;
        if(total>=2) { uint32_t index=firstChannel+c; if(index==0 && balance>0) side=1-balance; else if(index==1 && balance<0) side=1+balance; }
        vg[c]=volume*side;
    }
    if(!atomic_load_explicit(&e->level,memory_order_relaxed)) {
        if(firstChannel==0) { e->levelGain=1; e->levelPower=0; atomic_store_explicit(&e->levelDb,0,memory_order_relaxed); }
        for(uint32_t f=0;f<frames;f++) for(uint32_t c=0;c<channels;c++) data[f*channels+c]*=vg[c];
        return;
    }
    double startGain=e->levelGain;
    if(firstChannel==0 && frames) {
        double sum=0; for(uint32_t i=0;i<frames*channels;i++) sum+=(double)data[i]*data[i];
        double ms=sum/((double)frames*channels);
        // Silence and gaps between songs must not pull the gain up: hold the last value.
        if(ms>1e-7) {
            if(e->levelPower<=0) e->levelPower=ms;
            double tau=ms>e->levelPower?1.0:5.0;
            e->levelPower+=(1-exp(-(double)frames/(e->rate*tau)))*(ms-e->levelPower);
            double db=LEVEL_TARGET_DB-10*log10(e->levelPower);
            db=fmax(LEVEL_MAX_CUT_DB,fmin(LEVEL_MAX_BOOST_DB,db));
            e->levelGain=pow(10,db/20);
            atomic_store_explicit(&e->levelDb,db,memory_order_relaxed);
        }
    }
    double endGain=e->levelGain, step=frames?(endGain-startGain)/frames:0;
    for(uint32_t f=0;f<frames;f++) {
        double g=startGain+step*f;
        for(uint32_t c=0;c<channels;c++) {
            double x=data[f*channels+c]*g, a=fabs(x);
            if(a>0.89) x=copysign(0.89+0.11*tanh((a-0.89)/0.11),x);
            data[f*channels+c]=(float)x*vg[c];
        }
    }
}
void rp_eq_prepare(RPEQ *e, double sampleRate) {
    e->rate=sampleRate>0?sampleRate:44100;
    e->levelPower=0; e->levelGain=1; atomic_store(&e->levelDb,0);
    e->spaceApplied=-1;
    memset(e->z1,0,sizeof(e->z1)); memset(e->z2,0,sizeof(e->z2));
    memset(e->current,0,sizeof(e->current));
    atomic_store(&e->frames,0);
    for(int i=0;i<RP_VIS_RING;i++) atomic_store_explicit(&e->vis[i],0,memory_order_relaxed);
    atomic_store_explicit(&e->visWrite,0,memory_order_release);
}
double rp_eq_rate(RPEQ *e) { return e ? e->rate : 44100; }
uint32_t rp_vis_read(RPEQ *e, float *out, uint32_t count) {
    if(!e || !out || count==0 || count>RP_VIS_RING/2) return 0;
    uint64_t end=atomic_load_explicit(&e->visWrite,memory_order_acquire);
    uint32_t have=end<count?(uint32_t)end:count;
    uint32_t pad=count-have;
    for(uint32_t i=0;i<pad;i++) out[i]=0;
    for(uint32_t i=0;i<have;i++) out[pad+i]=atomic_load_explicit(&e->vis[(end-have+i)%RP_VIS_RING],memory_order_relaxed);
    return have;
}
static inline void vis_push(RPEQ *e,uint64_t *cursor,float sample) {
    atomic_store_explicit(&e->vis[*cursor%RP_VIS_RING],sample,memory_order_relaxed); (*cursor)++;
}
void rp_eq_process(RPEQ *e,float *data,uint32_t frames,uint32_t channels,uint32_t firstChannel) {
    if(!e || !data || !channels || firstChannel+channels>8) return;
    const float volume=atomic_load_explicit(&e->volume,memory_order_relaxed);
    const int enabled=atomic_load_explicit(&e->enabled,memory_order_relaxed);
    double target[11];
    for(int i=0;i<11;i++) {
        target[i]=enabled?atomic_load_explicit(&e->target[i],memory_order_relaxed):0;
    }
    // Smooth gain changes over roughly 20 ms; fixed storage and no locks or allocations.
    double blend=1-exp(-(double)frames/(e->rate*.020));
    int flat=1;
    if(firstChannel==0) for(int i=0;i<11;i++) {
        e->current[i]+=blend*(target[i]-e->current[i]);
        if(fabs(target[i]-e->current[i])<.0001) e->current[i]=target[i];
    }
    for(int i=0;i<11;i++) if(fabs(e->current[i])>.00001) flat=0;
    if(flat) {
        memset(e->z1,0,sizeof(e->z1)); memset(e->z2,0,sizeof(e->z2));
        if(firstChannel==0) {
            uint64_t cursor=atomic_load_explicit(&e->visWrite,memory_order_relaxed);
            for(uint32_t f=0;f<frames;f++) vis_push(e,&cursor,channels>1?(data[f*channels]+data[f*channels+1])*.5f:data[f*channels]);
            atomic_store_explicit(&e->visWrite,cursor,memory_order_release);
        }
        space(e,data,frames,channels,firstChannel);
        finish(e,data,frames,channels,firstChannel,volume);
        atomic_fetch_add_explicit(&e->frames,frames,memory_order_relaxed);
        atomic_store_explicit(&e->ratio,1,memory_order_relaxed); return;
    }
    if(firstChannel==0) for(int i=0;i<10;i++) {
        if(frequencies[i]>=e->rate*.49) { e->b0[i]=1;e->b1[i]=e->b2[i]=e->a1[i]=e->a2[i]=0;continue; }
        double A=pow(10,e->current[i+1]/40),w=2*M_PI*frequencies[i]/e->rate;
        double alpha=sin(w)/(2*1.4),a0=1+alpha/A;
        e->b0[i]=(1+alpha*A)/a0;e->b1[i]=-2*cos(w)/a0;e->b2[i]=(1-alpha*A)/a0;
        e->a1[i]=-2*cos(w)/a0;e->a2[i]=(1-alpha/A)/a0;
    }
    double gain=pow(10,e->current[0]/20),inputEnergy=0,outputEnergy=0;
    uint64_t cursor=atomic_load_explicit(&e->visWrite,memory_order_relaxed);
    for(uint32_t f=0;f<frames;f++) {
    float mix=0;
    for(uint32_t c=0;c<channels;c++) {
        uint32_t index=f*channels+c,ch=firstChannel+c;
        double x=data[index]; inputEnergy+=x*x; x*=gain;
        for(int b=0;b<10;b++) {
            double y=e->b0[b]*x+e->z1[ch][b];
            e->z1[ch][b]=e->b1[b]*x-e->a1[b]*y+e->z2[ch][b];
            e->z2[ch][b]=e->b2[b]*x-e->a2[b]*y;
            x=y;
        }
        // Prevent boosted presets from sending out-of-range samples to the device.
        if(!isfinite(x)) x=0;
        x=fmax(-1,fmin(1,x)); data[index]=(float)x; outputEnergy+=x*x;
        if(firstChannel==0 && c<2) mix+=(float)x*(channels>1?.5f:1.f);
    }
    if(firstChannel==0) vis_push(e,&cursor,mix);
    }
    if(firstChannel==0) atomic_store_explicit(&e->visWrite,cursor,memory_order_release);
    space(e,data,frames,channels,firstChannel);
    finish(e,data,frames,channels,firstChannel,volume);
    atomic_fetch_add_explicit(&e->frames,frames,memory_order_relaxed);
    atomic_store_explicit(&e->ratio,inputEnergy>1e-15?sqrt(outputEnergy/inputEnergy):1,memory_order_relaxed);
}
uint64_t rp_eq_frames(RPEQ *e) { return atomic_load_explicit(&e->frames,memory_order_relaxed); }
double rp_eq_ratio(RPEQ *e) { return atomic_load_explicit(&e->ratio,memory_order_relaxed); }
