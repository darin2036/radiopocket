#include "CEQ.h"
#include <stdlib.h>
#include <math.h>
#include <stdatomic.h>
#include <string.h>
#define RP_VIS_RING 8192
struct RPEQ {
    // Single-producer (audio thread) / single-consumer (UI thread) ring of mono post-EQ,
    // pre-volume samples for the visualizer. Fixed storage; relaxed atomics, release/acquire on the cursor.
    _Atomic float vis[RP_VIS_RING];
    _Atomic uint64_t visWrite;
    _Atomic float target[11];
    _Atomic int enabled;
    _Atomic float volume;
    _Atomic uint64_t frames;
    _Atomic double ratio;
    double rate, b0[10], b1[10], b2[10], a1[10], a2[10];
    double z1[8][10], z2[8][10], current[11];
};
static const double frequencies[10] = {60,170,310,600,1000,3000,6000,12000,14000,16000};
RPEQ *rp_eq_create(void) {
    RPEQ *e=calloc(1,sizeof(RPEQ));
    if(e) { e->rate=44100; atomic_store(&e->volume,1); atomic_store(&e->ratio,1); }
    return e;
}
void rp_eq_destroy(RPEQ *e) { free(e); }
void rp_eq_set(RPEQ *e, int enabled, float preamp, const float *bands) {
    atomic_store_explicit(&e->target[0],fmaxf(-12,fminf(12,preamp)),memory_order_relaxed);
    for(int i=0;i<10;i++) atomic_store_explicit(&e->target[i+1],fmaxf(-12,fminf(12,bands[i])),memory_order_relaxed);
    atomic_store_explicit(&e->enabled,enabled,memory_order_relaxed);
}
void rp_eq_volume(RPEQ *e, float volume) { atomic_store_explicit(&e->volume,fmaxf(0,fminf(1,volume)),memory_order_relaxed); }
void rp_eq_prepare(RPEQ *e, double sampleRate) {
    e->rate=sampleRate>0?sampleRate:44100;
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
        for(uint32_t i=0;i<frames*channels;i++) data[i]*=volume;
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
        x=fmax(-1,fmin(1,x)); data[index]=(float)x*volume; outputEnergy+=x*x;
        if(firstChannel==0 && c<2) mix+=(float)x*(channels>1?.5f:1.f);
    }
    if(firstChannel==0) vis_push(e,&cursor,mix);
    }
    if(firstChannel==0) atomic_store_explicit(&e->visWrite,cursor,memory_order_release);
    atomic_fetch_add_explicit(&e->frames,frames,memory_order_relaxed);
    atomic_store_explicit(&e->ratio,inputEnergy>1e-15?sqrt(outputEnergy/inputEnergy):1,memory_order_relaxed);
}
uint64_t rp_eq_frames(RPEQ *e) { return atomic_load_explicit(&e->frames,memory_order_relaxed); }
double rp_eq_ratio(RPEQ *e) { return atomic_load_explicit(&e->ratio,memory_order_relaxed); }
