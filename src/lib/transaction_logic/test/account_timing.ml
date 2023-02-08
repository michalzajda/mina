open! Core_kernel
open! Mina_transaction_logic
open Currency
open Mina_base
open Mina_numbers

type txn_result =
  ((Global_slot.t, Balance.t, Amount.t) Account_timing.tt, Error.t) Result.t
[@@deriving compare, sexp]

let%test_module "Test account timing." =
  ( module struct
    let%test_unit "Untimed accounts succeed if they have enough funds." =
      Quickcheck.test
        (let open Quickcheck.Generator.Let_syntax in
        let%bind account = Account.gen in
        let%bind amount =
          Amount.(gen_incl zero (Balance.to_amount account.balance))
        in
        let%map slot = Global_slot.gen in
        (account, amount, slot))
        ~f:(fun (account, txn_amount, txn_global_slot) ->
          [%test_eq: txn_result] (Ok Account.Timing.Poly.Untimed)
            (validate_timing ~account ~txn_amount ~txn_global_slot) )

    let%test_unit "Untimed accounts fail if funds are insufficient." =
      Quickcheck.test
        (let open Quickcheck.Generator.Let_syntax in
        (* We need to generate an amount strictly greater than the balance,
           therefore the balance cannot be at its maximum available value. *)
        let max_balance =
          let open Balance in
          max_int - Amount.one |> Option.value ~default:zero
        in
        let%bind account =
          Account.gen_with_constrained_balance ~low:Balance.zero
            ~high:max_balance
        in
        let min_amount =
          Amount.(Balance.to_amount account.balance + of_nanomina_int_exn 1)
          |> Option.value ~default:Amount.max_int
        in
        let%bind amount = Amount.gen_incl min_amount Amount.max_int in
        let%map slot = Global_slot.gen in
        (account, amount, slot))
        ~f:(fun (account, txn_amount, txn_global_slot) ->
          [%test_eq: txn_result]
            ( Or_error.errorf
                !"For timed account, the requested transaction for amount \
                  %{sexp: Amount.t} at global slot %{sexp: Global_slot.t}, the \
                  balance %{sexp: Balance.t} is insufficient"
                txn_amount txn_global_slot account.balance
            |> Result.map_error ~f:(Error.tag ~tag:nsf_tag) )
            (validate_timing ~account ~txn_amount ~txn_global_slot) )

    let%test_unit "Account with zero minimum balance becomes untimed." =
      Quickcheck.test
        (let open Quickcheck.Generator.Let_syntax in
        let%bind a = Account.gen_timed in
        let account =
          let open Account in
          let open Timing in
          match a.timing with
          | Untimed ->
              a
          | Timed t ->
              { a with
                timing = Timed { t with initial_minimum_balance = Balance.zero }
              }
        in
        let%bind amount =
          Amount.(gen_incl zero (Balance.to_amount account.balance))
        in
        let%map slot = Global_slot.gen in
        (account, amount, slot))
        ~f:(fun (account, txn_amount, txn_global_slot) ->
          [%test_eq: txn_result]
            (validate_timing ~account ~txn_amount ~txn_global_slot)
            (Ok Untimed) )

    let%test_unit "Before cliff time balance above the minimum can be spent." =
      Quickcheck.test
        (let open Quickcheck.Generator.Let_syntax in
        let%bind account = Account.gen_timed in
        let init_min_bal, cliff_time =
          match account.timing with
          | Account.Timing.Untimed ->
              assert false (* the generator only generates timed accounts. *)
          | Account.Timing.Timed t ->
              (t.initial_minimum_balance, t.cliff_time)
        in
        let max_amount =
          let open Balance in
          account.balance - to_amount init_min_bal
          |> Option.value_map ~default:Amount.zero ~f:to_amount
        in
        let%bind amount = Amount.(gen_incl zero max_amount) in
        let max_slot = Global_slot.(of_int (to_int cliff_time - 1)) in
        let%map slot = Global_slot.(gen_incl zero max_slot) in
        (account, amount, slot))
        ~f:(fun (account, txn_amount, txn_global_slot) ->
          [%test_eq: txn_result]
            (validate_timing ~account ~txn_amount ~txn_global_slot)
            (Ok account.timing) )

    let%test_unit "Minimum balance decreases over time." =
      Quickcheck.test
        (let open Quickcheck.Generator.Let_syntax in
        let%bind account = Account.gen_timed in
        let initial_minimum_balance, cliff_time =
          match account.timing with
          | Account.Timing.Untimed ->
              assert false (* the generator only generates timed accounts. *)
          | Account.Timing.Timed t ->
              (t.initial_minimum_balance, t.cliff_time)
        in
        let available_amount =
          let open Balance in
          account.balance - to_amount initial_minimum_balance
          |> Option.value_map ~f:Balance.to_amount ~default:Amount.zero
        in
        let%bind amount = Amount.(gen_incl zero available_amount) in
        let%map slot = Global_slot.(gen_incl cliff_time max_value) in
        (account, amount, slot))
        ~f:(fun (account, txn_amount, txn_global_slot) ->
          let open Account.Timing in
          [%test_pred: txn_result]
            (function
              | Ok Untimed ->
                  true
              | Ok (Timed t) -> (
                  match account.Account.Poly.timing with
                  | Untimed ->
                      false
                  | Timed initial_t ->
                      let open Balance in
                      t.initial_minimum_balance
                      <= initial_t.initial_minimum_balance )
              | Error _ ->
                  false )
            (validate_timing ~account ~txn_amount ~txn_global_slot) )

    let%test_unit "Timed accounts fail if minimum balance would be violated." =
      Quickcheck.test
        (let open Quickcheck.Generator.Let_syntax in
        let%bind account = Account.gen_timed in
        let initial_minimum_balance, cliff_time =
          match account.timing with
          | Account.Timing.Untimed ->
              assert false (* the generator only generates timed accounts. *)
          | Account.Timing.Timed t ->
              (t.initial_minimum_balance, t.cliff_time)
        in
        let available_amount =
          let open Balance in
          (let open Option.Let_syntax in
          let%bind avail =
            account.balance - to_amount initial_minimum_balance
          in
          Amount.(to_amount avail + of_nanomina_int_exn 1))
          |> Option.value ~default:Amount.zero
        in
        let%bind amount =
          Amount.(gen_incl available_amount (Balance.to_amount account.balance))
        in
        let%map slot =
          Global_slot.(gen_incl zero (of_int @@ (to_int cliff_time - 1)))
        in
        (initial_minimum_balance, account, amount, slot))
        ~f:(fun (min_balance, account, txn_amount, txn_global_slot) ->
          [%test_eq: txn_result]
            ( Or_error.errorf
                !"For timed account, the requested transaction for amount \
                  %{sexp: Amount.t} at global slot %{sexp: Global_slot.t}, \
                  applying the transaction would put the balance below the \
                  calculated minimum balance of %{sexp: Balance.t}"
                txn_amount txn_global_slot min_balance
            |> Or_error.tag ~tag:min_balance_tag )
            (validate_timing ~account ~txn_amount ~txn_global_slot) )
  end )
