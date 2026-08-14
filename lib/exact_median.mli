(** Exact median of an append-only stream of finite floats.

    No [merge] operation is exposed: the two heaps retain the full stream and
    do not have the constant-size merge contract of a moments accumulator. *)

type t

type error = [ `Non_finite ]

(** [create ()] returns an empty accumulator. *)
val create : unit -> t

(** [add t x] inserts [x] in [O(log n)] time. NaN and infinities are rejected
    before [t] is changed. *)
val add : t -> float -> (unit, error) result

(** Number of retained observations. *)
val count : t -> int64

(** Exact median in [O(1)] time, or [None] for an empty stream. The accumulator
    retains all observations and therefore uses [O(n)] memory. For an even
    count, the midpoint calculation avoids overflow at finite floating-point
    extremes. *)
val value : t -> float option
