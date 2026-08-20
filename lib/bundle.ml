type randomized = { capacity : int; seed : int }

type create_error =
  | Invalid_reservoir_capacity of int
  | Invalid_kll_capacity of int

type add_error = [ `Non_finite | `Count_overflow ]

type 'a configured = Disabled | Enabled of 'a

type t = {
  summary : Summary.t;
  exact_median : Exact_median.t option;
  reservoir : float Reservoir.t option;
  kll : Kll.t option;
}

let create ?(exact_median = false) ?reservoir ?kll () =
  let reservoir_result =
    match reservoir with
    | None -> Ok None
    | Some { capacity; seed } -> (
        match Reservoir.create ~capacity ~seed with
        | Ok state -> Ok (Some state)
        | Error (`Invalid_capacity invalid) ->
            Error (Invalid_reservoir_capacity invalid))
  in
  match reservoir_result with
  | Error _ as error -> error
  | Ok reservoir -> (
      match kll with
      | Some { capacity; _ } when capacity < 8 ->
          Error (Invalid_kll_capacity capacity)
      | Some { capacity; _ } when capacity >= Sys.max_array_length ->
          Error (Invalid_kll_capacity capacity)
      | kll_config ->
          let kll =
            Option.map
              (fun { capacity; seed } -> Kll.create ~capacity ~seed ())
              kll_config
          in
          Ok
            {
              summary = Summary.create ();
              exact_median =
                (if exact_median then Some (Exact_median.create ()) else None);
              reservoir;
              kll;
            })

let add t value =
  if not (Float.is_finite value) then Error `Non_finite
  else if Int64.equal (Summary.count t.summary) Int64.max_int then
    Error `Count_overflow
  else
    match Summary.add t.summary value with
    | Error error -> Error error
    | Ok () ->
        Option.iter
          (fun median ->
            match Exact_median.add median value with
            | Ok () -> ()
            | Error `Non_finite -> assert false)
          t.exact_median;
        Option.iter
          (fun reservoir ->
            match Reservoir.add reservoir value with
            | Ok () -> ()
            | Error `Count_overflow -> assert false)
          t.reservoir;
        Option.iter
          (fun kll ->
            match Kll.add kll value with
            | Ok () -> ()
            | Error `Non_finite -> assert false
            | Error `Count_overflow -> assert false)
          t.kll;
        Ok ()

let count t = Summary.count t.summary
let sum t = Summary.sum t.summary
let min t = Summary.min t.summary
let max t = Summary.max t.summary
let mean t = Summary.mean t.summary
let population_variance t = Summary.population_variance t.summary
let sample_variance t = Summary.sample_variance t.summary

let exact_median t =
  match t.exact_median with
  | None -> Disabled
  | Some median -> Enabled (Exact_median.value median)

let reservoir_sample t =
  match t.reservoir with
  | None -> Disabled
  | Some reservoir -> Enabled (Reservoir.sample reservoir)

let approximate_quantile t ~q =
  match t.kll with
  | None -> Disabled
  | Some kll -> Enabled (Kll.quantile kll ~q)

let kll_retained t =
  match t.kll with None -> Disabled | Some kll -> Enabled (Kll.retained kll)
