(** A concrete one-pass composition of the univariate accumulators.

    [Bundle] does not add a common [merge] operation. The components keep the
    capabilities and costs documented by their own modules. *)

type t

type randomized = { capacity : int; seed : int }

type create_error =
  | Invalid_reservoir_capacity of int
  | Invalid_kll_capacity of int

type add_error = [ `Non_finite | `Count_overflow ]

type 'a configured = Disabled | Enabled of 'a

val create :
  ?exact_median:bool ->
  ?reservoir:randomized ->
  ?kll:randomized ->
  unit ->
  (t, create_error) result
(** Creates an accumulator bundle. [Summary] is always enabled. The exact
    median is disabled by default; randomized components require an explicit
    capacity and seed. *)

val add : t -> float -> (unit, add_error) result
(** Feeds one finite observation to every enabled component. A rejected input
    leaves the whole bundle unchanged. *)

val count : t -> int64
val sum : t -> float
val min : t -> float option
val max : t -> float option
val mean : t -> float option
val population_variance : t -> float option
val sample_variance : t -> float option

val exact_median : t -> float option configured
val reservoir_sample : t -> float array configured
val approximate_quantile : t -> q:float -> float option configured
(** Relays {!Kll.quantile} when KLL is enabled, including its
    [Invalid_argument] exception for a non-finite [q] or one outside [[0, 1]]. *)

val kll_retained : t -> int configured
