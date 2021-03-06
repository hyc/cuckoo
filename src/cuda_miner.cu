// Cuckoo Cycle, a memory-hard proof-of-work
// Copyright (c) 2013-2015 John Tromp

// The edge-trimming time-memory trade-off is due to Dave Anderson:
// http://da-data.blogspot.com/2014/03/a-public-review-of-cuckoo-cycle.html

#include <stdint.h>
#include <string.h>
#include "cuckoo.h"
#if SIZESHIFT <= 32
  typedef u32 nonce_t;
  typedef u32 node_t;
#else
  typedef u64 nonce_t;
  typedef u64 node_t;
#endif
#include <openssl/sha.h>

// d(evice s)ipnode
#if (__CUDA_ARCH__  >= 320) // redefine ROTL to use funnel shifter, 3% speed gain

static __device__ __forceinline__ uint2 operator^ (uint2 a, uint2 b) { return make_uint2(a.x ^ b.x, a.y ^ b.y); }
static __device__ __forceinline__ void operator^= (uint2 &a, uint2 b) { a.x ^= b.x, a.y ^= b.y; }
static __device__ __forceinline__ void operator+= (uint2 &a, uint2 b) {
  asm("{\n\tadd.cc.u32 %0,%2,%4;\n\taddc.u32 %1,%3,%5;\n\t}\n\t"
    : "=r"(a.x), "=r"(a.y) : "r"(a.x), "r"(a.y), "r"(b.x), "r"(b.y));
}
#undef ROTL
__inline__ __device__ uint2 ROTL(const uint2 a, const int offset) {
  uint2 result;
  if (offset >= 32) {
    asm("shf.l.wrap.b32 %0, %1, %2, %3;" : "=r"(result.x) : "r"(a.x), "r"(a.y), "r"(offset));
    asm("shf.l.wrap.b32 %0, %1, %2, %3;" : "=r"(result.y) : "r"(a.y), "r"(a.x), "r"(offset));
  } else {
    asm("shf.l.wrap.b32 %0, %1, %2, %3;" : "=r"(result.x) : "r"(a.y), "r"(a.x), "r"(offset));
    asm("shf.l.wrap.b32 %0, %1, %2, %3;" : "=r"(result.y) : "r"(a.x), "r"(a.y), "r"(offset));
  }
  return result;
}
__device__ __forceinline__ uint2 vectorize(const uint64_t x) {
  uint2 result;
  asm("mov.b64 {%0,%1},%2; \n\t" : "=r"(result.x), "=r"(result.y) : "l"(x));
  return result;
}
__device__ __forceinline__ uint64_t devectorize(uint2 x) {
  uint64_t result;
  asm("mov.b64 %0,{%1,%2}; \n\t" : "=l"(result) : "r"(x.x), "r"(x.y));
  return result;
}
__device__ node_t dipnode(siphash_ctx &ctx, nonce_t nce, u32 uorv) {
  uint2 nonce = vectorize(2*nce + uorv);
  uint2 v0 = ctx.v2[0], v1 = ctx.v2[1], v2 = ctx.v2[2], v3 = ctx.v2[3] ^ nonce;
  SIPROUND; SIPROUND;
  v0 ^= nonce;
  v2 ^= vectorize(0xff);
  SIPROUND; SIPROUND; SIPROUND; SIPROUND;
  return devectorize(v0 ^ v1 ^ v2  ^ v3) & NODEMASK;
}

#else

__device__ node_t dipnode(siphash_ctx &ctx, nonce_t nce, u32 uorv) {
  u64 nonce = 2*nce + uorv;
  u64 v0 = ctx.v[0], v1 = ctx.v[1], v2 = ctx.v[2], v3 = ctx.v[3] ^ nonce;
  SIPROUND; SIPROUND;
  v0 ^= nonce;
  v2 ^= 0xff;
  SIPROUND; SIPROUND; SIPROUND; SIPROUND;
  return (v0 ^ v1 ^ v2  ^ v3) & NODEMASK;
}

#endif

#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <set>

// algorithm parameters
#ifndef PART_BITS
// #bits used to partition edge set processing to save memory
// a value of 0 does no partitioning and is fastest
// a value of 1 partitions in two, making twice_set the
// same size as shrinkingset at about 33% slowdown
// higher values are not that interesting
#define PART_BITS 0
#endif

#ifndef IDXSHIFT
// we want sizeof(cuckoo_hash) == sizeof(twice_set), so
// CUCKOO_SIZE * sizeof(u64) == TWICE_WORDS * sizeof(u32)
// CUCKOO_SIZE * 2 == TWICE_WORDS
// (SIZE >> IDXSHIFT) * 2 == 2 * ONCE_BITS / 32
// SIZE >> IDXSHIFT == HALFSIZE >> PART_BITS >> 5
// IDXSHIFT == 1 + PART_BITS + 5
#define IDXSHIFT (PART_BITS + 6)
#endif
// grow with cube root of size, hardly affected by trimming
#define MAXPATHLEN (8 << (SIZESHIFT/3))

#define checkCudaErrors(ans) { gpuAssert((ans), __FILE__, __LINE__); }
inline void gpuAssert(cudaError_t code, const char *file, int line, bool abort=true) {
  if (code != cudaSuccess) {
    fprintf(stderr,"GPUassert: %s %s %d\n", cudaGetErrorString(code), file, line);
    if (abort) exit(code);
  }
}

// set that starts out full and gets reset by threads on disjoint words
class shrinkingset {
public:
  u32 *bits;
  __device__ void reset(nonce_t n) {
    bits[n/32] |= 1 << (n%32);
  }
  __device__ bool test(node_t n) const {
    return !((bits[n/32] >> (n%32)) & 1);
  }
  __device__ u32 block(node_t n) const {
    return ~bits[n/32];
  }
};

#define PART_MASK ((1 << PART_BITS) - 1)
#define ONCE_BITS (HALFSIZE >> PART_BITS)
#define TWICE_WORDS ((2 * ONCE_BITS) / 32)

class twice_set {
public:
  u32 *bits;
  __device__ void reset() {
    memset(bits, 0, TWICE_WORDS * sizeof(u32));
  }
  __device__ void set(node_t u) {
    node_t idx = u/16;
    u32 bit = 1 << (2 * (u%16));
    u32 old = atomicOr(&bits[idx], bit);
    u32 bit2 = bit<<1;
    if ((old & (bit2|bit)) == bit) atomicOr(&bits[idx], bit2);
  }
  __device__ u32 test(node_t u) const {
    return (bits[u/16] >> (2 * (u%16))) & 2;
  }
};

#define CUCKOO_SIZE (SIZE >> IDXSHIFT)
#define CUCKOO_MASK (CUCKOO_SIZE - 1)
// number of (least significant) key bits that survives leftshift by SIZESHIFT
#define KEYBITS (64-SIZESHIFT)
#define KEYMASK ((1L << KEYBITS) - 1)
#define MAXDRIFT (1L << (KEYBITS - IDXSHIFT))

class cuckoo_hash {
public:
  u64 *cuckoo;

  cuckoo_hash() {
    cuckoo = (u64 *)calloc(CUCKOO_SIZE, sizeof(u64));
    assert(cuckoo != 0);
  }
  ~cuckoo_hash() {
    free(cuckoo);
  }
  void set(node_t u, node_t v) {
    u64 niew = (u64)u << SIZESHIFT | v;
    for (node_t ui = u >> IDXSHIFT; ; ui = (ui+1) & CUCKOO_MASK) {
#ifdef ATOMIC
      u64 old = 0;
      if (cuckoo[ui].compare_exchange_strong(old, niew, std::memory_order_relaxed))
        return;
      if ((old >> SIZESHIFT) == (u & KEYMASK)) {
        cuckoo[ui].store(niew, std::memory_order_relaxed);
#else
      u64 old = cuckoo[ui];
      if (old == 0 || (old >> SIZESHIFT) == (u & KEYMASK)) {
        cuckoo[ui] = niew;
#endif
        return;
      }
    }
  }
  node_t operator[](node_t u) const {
    for (node_t ui = u >> IDXSHIFT; ; ui = (ui+1) & CUCKOO_MASK) {
#ifdef ATOMIC
      u64 cu = cuckoo[ui].load(std::memory_order_relaxed);
#else
      u64 cu = cuckoo[ui];
#endif
      if (!cu)
        return 0;
      if ((cu >> SIZESHIFT) == (u & KEYMASK)) {
        assert(((ui - (u >> IDXSHIFT)) & CUCKOO_MASK) < MAXDRIFT);
        return (node_t)(cu & (SIZE-1));
      }
    }
  }
};

class cuckoo_ctx {
public:
  siphash_ctx sip_ctx;
  shrinkingset alive;
  twice_set nonleaf;
  int nthreads;

  cuckoo_ctx(const char* header, u32 n_threads) {
    setheader(&sip_ctx, header);
    nthreads = n_threads;
  }
};

__global__ void count_node_deg(cuckoo_ctx *ctx, u32 uorv, u32 part) {
  shrinkingset &alive = ctx->alive;
  twice_set &nonleaf = ctx->nonleaf;
  siphash_ctx sip_ctx = ctx->sip_ctx; // local copy sip context; 2.5% speed gain
  int id = blockIdx.x * blockDim.x + threadIdx.x;
  for (nonce_t block = id*32; block < HALFSIZE; block += ctx->nthreads*32) {
    u32 alive32 = alive.block(block);
    for (nonce_t nonce = block-1; alive32; ) { // -1 compensates for 1-based ffs
      u32 ffs = __ffs(alive32);
      nonce += ffs; alive32 >>= ffs;
      node_t u = dipnode(sip_ctx, nonce, uorv);
      if ((u & PART_MASK) == part) {
        nonleaf.set(u >> PART_BITS);
      }
    }
  }
}

__global__ void kill_leaf_edges(cuckoo_ctx *ctx, u32 uorv, u32 part) {
  shrinkingset &alive = ctx->alive;
  twice_set &nonleaf = ctx->nonleaf;
  siphash_ctx sip_ctx = ctx->sip_ctx;
  int id = blockIdx.x * blockDim.x + threadIdx.x;
  for (nonce_t block = id*32; block < HALFSIZE; block += ctx->nthreads*32) {
    u32 alive32 = alive.block(block);
    for (nonce_t nonce = block-1; alive32; ) { // -1 compensates for 1-based ffs
      u32 ffs = __ffs(alive32);
      nonce += ffs; alive32 >>= ffs;
      node_t u = dipnode(sip_ctx, nonce, uorv);
      if ((u & PART_MASK) == part) {
        if (!nonleaf.test(u >> PART_BITS)) {
          alive.reset(nonce);
        }
      }
    }
  }
}

u32 path(cuckoo_hash &cuckoo, node_t u, node_t *us) {
  u32 nu;
  for (nu = 0; u; u = cuckoo[u]) {
    if (++nu >= MAXPATHLEN) {
      while (nu-- && us[nu] != u) ;
      if (nu == ~0)
        printf("maximum path length exceeded\n");
      else printf("illegal % 4d-cycle\n", MAXPATHLEN-nu);
      exit(0);
    }
    us[nu] = u;
  }
  return nu;
}

typedef std::pair<node_t,node_t> edge;

#include <unistd.h>

int main(int argc, char **argv) {
  int nthreads = 1;
  int ntrims   = 1 + (PART_BITS+3)*(PART_BITS+4)/2;
  int tpb = 0;
  const char *header = "";
  int c;
  while ((c = getopt (argc, argv, "h:n:t:p:")) != -1) {
    switch (c) {
      case 'h':
        header = optarg;
        break;
      case 'n':
        ntrims = atoi(optarg);
        break;
      case 't':
        nthreads = atoi(optarg);
        break;
      case 'p':
        tpb = atoi(optarg);
        break;
    }
  }
  if (!tpb) // if not set, then default threads per block to roughly square root of threads
    for (tpb = 1; tpb*tpb < nthreads; tpb *= 2) ;

  printf("Looking for %d-cycle on cuckoo%d(\"%s\") with 50%% edges, %d trims, %d threads %d per block\n",
               PROOFSIZE, SIZESHIFT, header, ntrims, nthreads, tpb);
  u64 edgeBytes = HALFSIZE/8, nodeBytes = TWICE_WORDS*sizeof(u32);

  cuckoo_ctx ctx(header, nthreads);
  checkCudaErrors(cudaMalloc((void**)&ctx.alive.bits, edgeBytes));
  checkCudaErrors(cudaMemset(ctx.alive.bits, 0, edgeBytes));
  checkCudaErrors(cudaMalloc((void**)&ctx.nonleaf.bits, nodeBytes));

  int edgeUnit=0, nodeUnit=0;
  u64 eb = edgeBytes, nb = nodeBytes;
  for (; eb >= 1024; eb>>=10) edgeUnit++;
  for (; nb >= 1024; nb>>=10) nodeUnit++;
  printf("Using %d%cB edge and %d%cB node memory.\n",
     (int)eb, " KMGT"[edgeUnit], (int)nb, " KMGT"[nodeUnit]);

  cuckoo_ctx *device_ctx;
  checkCudaErrors(cudaMalloc((void**)&device_ctx, sizeof(cuckoo_ctx)));
  cudaMemcpy(device_ctx, &ctx, sizeof(cuckoo_ctx), cudaMemcpyHostToDevice);

  for (u32 round=0; round < ntrims; round++) {
    for (u32 uorv = 0; uorv < 2; uorv++) {
      for (u32 part = 0; part <= PART_MASK; part++) {
        checkCudaErrors(cudaMemset(ctx.nonleaf.bits, 0, nodeBytes));
        count_node_deg<<<nthreads/tpb,tpb >>>(device_ctx, uorv, part);
        kill_leaf_edges<<<nthreads/tpb,tpb >>>(device_ctx, uorv, part);
      }
    }
  }

  u64 *bits;
  bits = (u64 *)calloc(HALFSIZE/64, sizeof(u64));
  assert(bits != 0);
  cudaMemcpy(bits, ctx.alive.bits, (HALFSIZE/64) * sizeof(u64), cudaMemcpyDeviceToHost);
  checkCudaErrors(cudaFree(ctx.alive.bits));
  checkCudaErrors(cudaFree(ctx.nonleaf.bits));

  u32 cnt = 0;
  for (int i = 0; i < HALFSIZE/64; i++)
    cnt += __builtin_popcountll(~bits[i]);
  u32 load = (u32)(100L * cnt / CUCKOO_SIZE);
  printf("final load %d%%\n", load);

  if (load >= 90) {
    printf("overloaded! exiting...");
    exit(0);
  }

  cuckoo_hash &cuckoo = *(new cuckoo_hash());
  node_t us[MAXPATHLEN], vs[MAXPATHLEN];
  for (nonce_t block = 0; block < HALFSIZE; block += 64) {
    u64 alive64 = ~bits[block/64];
    for (nonce_t nonce = block-1; alive64; ) { // -1 compensates for 1-based ffs
      u32 ffs = __builtin_ffsll(alive64);
      nonce += ffs; alive64 >>= ffs;
      node_t u0=sipnode(&ctx.sip_ctx, nonce, 0), v0=sipnode(&ctx.sip_ctx, nonce, 1);
      if (u0 == 0) // ignore vertex 0 so it can be used as nil for cuckoo[]
        continue;
      node_t u = cuckoo[us[0] = u0], v = cuckoo[vs[0] = v0];
      u32 nu = path(cuckoo, u, us), nv = path(cuckoo, v, vs);
      if (us[nu] == vs[nv]) {
        u32 min = nu < nv ? nu : nv;
        for (nu -= min, nv -= min; us[nu] != vs[nv]; nu++, nv++) ;
        u32 len = nu + nv + 1;
        printf("% 4d-cycle found at %d:%d%%\n", len, 0, (u32)(nonce*100L/HALFSIZE));
        if (len == PROOFSIZE) {
          printf("Solution");
          std::set<edge> cycle;
          u32 n = 0;
          cycle.insert(edge(*us, *vs));
          while (nu--)
            cycle.insert(edge(us[(nu+1)&~1], us[nu|1])); // u's in even position; v's in odd
          while (nv--)
            cycle.insert(edge(vs[nv|1], vs[(nv+1)&~1])); // u's in odd position; v's in even
          for (nonce_t blk = 0; blk < HALFSIZE; blk += 64) {
            u64 alv64 = ~bits[blk/64];
            for (nonce_t nce = blk-1; alv64; ) { // -1 compensates for 1-based ffs
              u32 ffs = __builtin_ffsll(alv64);
              nce += ffs; alv64 >>= ffs;
              edge e(sipnode(&ctx.sip_ctx, nce, 0), sipnode(&ctx.sip_ctx, nce, 1));
              if (cycle.find(e) != cycle.end()) {
                printf(" %x", nce);
                if (PROOFSIZE > 2)
                  cycle.erase(e);
                n++;
              }
              if (ffs & 64) break; // can't shift by 64
            }
          }
          assert(n==PROOFSIZE);
          printf("\n");
        }
        continue;
      }
      if (nu < nv) {
        while (nu--)
          cuckoo.set(us[nu+1], us[nu]);
        cuckoo.set(u0, v0);
      } else {
        while (nv--)
          cuckoo.set(vs[nv+1], vs[nv]);
        cuckoo.set(v0, u0);
      }
      if (ffs & 64) break; // can't shift by 64
    }
  }
  return 0;
}
