(** A concrete one-pass composition of the univariate accumulators.

    [Bundle] does not add a common [merge] operation. The components keep the
    capabilities and costs documented by their own modules. *)

type t

(** Capacity and seed for a randomized component. *)
type randomized = { capacity : int; seed : int }

(** Invalid capacity of the named optional component. *)
type create_error =
  | Invalid_reservoir_capacity of int
  | Invalid_kll_capacity of int

(** Rejected value or exhausted [int64] observation count. *)
type add_error = [ `Non_finite | `Count_overflow ]

(** Whether an optional component was configured. *)
type 'a configured = Disabled | Enabled of 'a

val create :
  ?exact_median:bool ->
  ?reservoir:randomized ->
  ?kll:randomized ->
  unit ->
  (t, create_error) result
(** Creates an accumulator bundle. [Summary] is always enabled. The exact
    median is disabled by default; randomized components require an explicit
    capacity and seed. Reservoir capacity must be positive. KLL capacity must
    be at least [8] and smaller than [Sys.max_array_length]. *)

val add : t -> float -> (unit, add_error) result
(** Feeds one finite observation to every enabled component. A rejected input
    leaves the whole bundle unchanged. *)

(** Number of accepted observations. *)
val count : t -> int64

(** Relays {!Summary.sum}. *)
val sum : t -> float

(** Relays {!Summary.min}. *)
val min : t -> float option

(** Relays {!Summary.max}. *)
val max : t -> float option

(** Relays {!Summary.mean}. *)
val mean : t -> float option

(** Relays {!Summary.population_variance}. *)
val population_variance : t -> float option

(** Relays {!Summary.sample_variance}. *)
val sample_variance : t -> float option

(** Exact median result, or [Disabled] when it was not configured. *)
val exact_median : t -> float option configured

(** Defensive copy of the reservoir sample, or [Disabled] when it was not
    configured. *)
val reservoir_sample : t -> float array configured

val approximate_quantile : t -> q:float -> float option configured
(** Relays {!Kll.quantile} when KLL is enabled, including its
    [Invalid_argument] exception for a non-finite [q] or one outside [[0, 1]]. *)

(** Number of values retained by KLL, or [Disabled] when it was not
    configured. *)
val kll_retained : t -> int configured
