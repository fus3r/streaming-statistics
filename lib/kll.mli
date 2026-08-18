(** Seeded KLL quantile sketch over finite floats.

    Values are retained in weighted levels: an item in level [i] represents
    weight [2^i]. If [h] levels currently exist, the capacity of level [i] is
    the configured capacity reduced [h - i - 1] times by
    [shrink x = ceil (2 * x / 3)], with a lower bound of [8]. An overflowing
    level is sorted and either its even- or odd-indexed items are promoted at
    random. For an odd population, one randomly selected endpoint remains at
    the current level so that total weight is conserved.

    Queries sort a temporary weighted view of the retained levels. Sketches
    with equal configured capacities can be merged using an explicit seed for
    result compactions. [capacity] controls the level schedule; it is neither a
    strict bound on retained items nor a claimed rank-error guarantee. *)

type t

type add_error = [ `Non_finite | `Count_overflow ]

type merge_error =
  [ `Incompatible_capacity of int * int | `Count_overflow ]

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

val minimum : t -> float option
val maximum : t -> float option
(** Exact extrema of the accepted stream, or [None] for an empty sketch. *)

val rank : t -> float -> float option
(** [rank t value] is the estimated inclusive normalized rank
    [weight (values <= value) / count t]. It returns [None] for an empty sketch
    and raises [Invalid_argument] when [value] is not finite. Equal values
    contribute their full retained weight to the same inclusive rank. A query
    sorts the retained weighted view in [O(r log r)] time and [O(r)] temporary
    memory, where [r] is {!retained}. *)

val quantile : t -> q:float -> float option
(** Return an observed stream value at normalized rank [q]. [q] must be finite
    and in [[0, 1]]; [Invalid_argument] is raised otherwise. The zero-based
    target is [floor (q * (count - 1))], with the binary64 value of [q]
    interpreted as an exact rational number. The result is the first retained
    value whose cumulative weight is strictly greater than that target.
    [q = 0] and [q = 1] return the exact stream extrema. Values are never
    interpolated, including across ties. An empty sketch returns [None]. *)

val merge : seed:int -> t -> t -> (t, merge_error) result
(** [merge ~seed left right] returns a new sketch and leaves its inputs
    unchanged. Inputs are compatible exactly when their configured capacities
    match. The explicit result seed drives compactions caused by the merge and
    all later additions. Given the same input states, argument order, result
    seed, and OCaml toolchain, the result is deterministic. No bitwise
    commutativity across merge orders is promised. *)

val check_invariants : t -> (unit, string) result
(** Check level capacities, retained-value finiteness, extrema, and equality
    between the total retained weight and {!count}. This linear diagnostic is
    intended for tests and investigations, not the update hot path. *)
