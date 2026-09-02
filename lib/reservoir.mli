(** Uniform reservoir sampling for append-only streams.

    No [merge] operation is exposed: Algorithm R alone does not define a
    uniform merge of independently populated reservoirs. *)

type 'a t

(** Invalid configured capacity. *)
type create_error = [ `Invalid_capacity of int ]

(** Exhausted [int64] observation count. *)
type add_error = [ `Count_overflow ]

val create : capacity:int -> seed:int -> ('a t, create_error) result
(** [create ~capacity ~seed] creates an Algorithm R reservoir with its own
    random state. [capacity] must be strictly positive. Equal seeds and input
    sequences reproduce within a fixed OCaml toolchain. *)

val add : 'a t -> 'a -> (unit, add_error) result
(** [add t x] observes [x] in expected [O(1)] time. It returns
    [`Count_overflow] without changing the sample or random state if the
    64-bit observation count is full. *)

(** Configured maximum sample size. *)
val capacity : 'a t -> int

(** Number of observations seen, including those not retained. *)
val count : 'a t -> int64

val sample : 'a t -> 'a array
(** A copy of the retained sample. Its slot order is not stream order. *)
