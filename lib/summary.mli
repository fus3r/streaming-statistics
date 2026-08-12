(** Numerically stable univariate statistics for an append-only stream. *)

type t

(** Rejected input or exhausted [int64] observation count. *)
type error = [ `Non_finite | `Count_overflow ]

(** Exhausted combined observation count. *)
type merge_error = [ `Count_overflow ]

(** [create ()] returns an empty mutable accumulator. *)
val create : unit -> t

(** Number of accepted observations. *)
val count : t -> int64

(** [add t x] updates [t]. Non-finite inputs and count overflow are reported
    without changing [t]. *)
val add : t -> float -> (unit, error) result

(** [merge left right] returns their Chan-combined summary without changing
    either input. *)
val merge : t -> t -> (t, merge_error) result

(** Compensated sum. The sum of an empty stream is [0.]. *)
val sum : t -> float

(** [min], [max], and [mean] are [None] for an empty stream. *)
val min : t -> float option
val max : t -> float option
val mean : t -> float option

(** Population quantities are [None] only when empty; sample quantities require
    at least two observations. *)
val population_variance : t -> float option
val sample_variance : t -> float option
val population_standard_deviation : t -> float option
val sample_standard_deviation : t -> float option
