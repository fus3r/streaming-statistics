(** Seeded compaction core for a KLL quantile sketch over finite floats.

    Values are retained in weighted levels: an item in level [i] represents
    weight [2^i]. If [h] levels currently exist, the capacity of level [i] is
    the configured capacity reduced [h - i - 1] times by
    [shrink x = ceil (2 * x / 3)], with a lower bound of [8]. An overflowing
    level is sorted and either its even- or odd-indexed items are promoted at
    random. For an odd population, one randomly selected endpoint remains at
    the current level so that total weight is conserved.

    This module currently exposes the compaction hierarchy only. Rank and
    quantile queries, and merging compatible sketches, are separate planned
    capabilities. [capacity] controls the level schedule; it is neither a
    strict bound on retained items nor a claimed rank-error guarantee. *)

type t

type add_error = [ `Non_finite | `Count_overflow ]

val create : capacity:int -> seed:int -> unit -> t
(** [create ~capacity ~seed ()] creates an empty sketch with a private random
    state. [capacity] must be at least [8] and smaller than
    [Sys.max_array_length]; otherwise [Invalid_argument] is raised. Equal
    seeds and update sequences reproduce within a fixed OCaml toolchain. *)

val add : t -> float -> (unit, add_error) result
(** [add t value] adds one finite value. A non-finite value or a full 64-bit
    observation count is rejected without changing the sketch or consuming
    randomness. The amortized cost includes sorting and compaction. *)

val capacity : t -> int
(** Configured capacity of the top level. *)

val count : t -> int64
(** Number of accepted observations, including observations represented only
    by promoted weights. *)

val retained : t -> int
(** Number of values physically retained across all levels. *)

val check_invariants : t -> (unit, string) result
(** Check level capacities, retained-value finiteness, and equality between the
    total retained weight and {!count}. This linear diagnostic is intended for
    tests and investigations, not the update hot path. *)
