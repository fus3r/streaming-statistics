(** Numerically stable statistics for an append-only stream of pairs. *)

type t

(** Rejected coordinate or exhausted [int64] pair count. *)
type error = [ `Non_finite | `Count_overflow ]

(** Exhausted combined pair count. *)
type merge_error = [ `Count_overflow ]

type regression = { slope : float; intercept : float }

(** [create ()] returns an empty mutable accumulator. *)
val create : unit -> t

(** Number of accepted pairs. *)
val count : t -> int64

(** [add t x y] updates [t]. If either coordinate is non-finite, or the count
    would overflow, the error is reported without changing [t]. *)
val add : t -> float -> float -> (unit, error) result

(** [merge left right] returns their Chan-combined statistics without changing
    either input. *)
val merge : t -> t -> (t, merge_error) result

(** Population covariance is [None] when empty; sample covariance requires at
    least two pairs. *)
val population_covariance : t -> float option
val sample_covariance : t -> float option

(** Pearson correlation, undefined when either marginal variance is zero or
    binary64 roundoff produces a value materially outside [[-1, 1]]. A result
    only a few ULP beyond an endpoint is rounded to that endpoint. *)
val correlation : t -> float option

(** Ordinary least-squares regression of [y] on [x], undefined with fewer than
    two pairs, zero variance in [x], or non-finite binary64 coefficients. *)
val linear_regression : t -> regression option
