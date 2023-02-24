open! Core_kernel
open Currency
open Mina_base
open Signature_lib

let dummy_auth = Control.Signature Signature.dummy

let update_body ~account amount =
  let open Monad_lib.State.Let_syntax in
  let open Account_update in
  let%map nonce = Helpers.get_nonce_exn account in
  Body.
    { dummy with
      public_key = account
    ; update = Account_update.Update.noop
    ; token_id = Token_id.default
    ; balance_change = amount
    ; increment_nonce = true
    ; implicit_account_creation_fee = true
    ; may_use_token = No
    ; authorization_kind = Signature
    ; preconditions =
        { network = Zkapp_precondition.Protocol_state.accept
        ; account = Account_precondition.Nonce nonce
        ; valid_while = Ignore
        }
    }

let update body =
  let open With_stack_hash in
  let open Zkapp_command.Call_forest.Tree in
  { elt =
      { account_update = body
      ; account_update_digest =
          Zkapp_command.Call_forest.Digest.Account_update.create body
      ; calls = []
      }
  ; stack_hash = Zkapp_command.Call_forest.Digest.Forest.empty
  }

module Simple_txn = struct
  let make ~sender ~receiver amount =
    object
      method sender : Public_key.Compressed.t = sender

      method receiver : Public_key.Compressed.t = receiver

      method amount : Amount.t = amount

      method updates
          : (Helpers.account_update list, Helpers.nonces) Monad_lib.State.t =
        let open Monad_lib.State.Let_syntax in
        let%bind sender_decrease_body =
          update_body ~account:sender
            Amount.Signed.(negate @@ of_unsigned amount)
        in
        let%map receiver_increase_body =
          update_body ~account:receiver Amount.Signed.(of_unsigned amount)
        in
        [ update
            Account_update.
              { body = sender_decrease_body; authorization = dummy_auth }
        ; update
            Account_update.
              { body = receiver_increase_body; authorization = dummy_auth }
        ]
    end

  let gen known_accounts =
    let open Quickcheck in
    let open Generator.Let_syntax in
    let make_txn = make in
    let open Helpers.Test_account in
    let eligible_senders = List.filter ~f:non_empty known_accounts in
    let%bind sender = Generator.of_list eligible_senders in
    let eligible_receivers =
      List.filter
        ~f:(fun a -> not Public_key.Compressed.(equal a.pk sender.pk))
        known_accounts
    in
    let%bind receiver = Generator.of_list eligible_receivers in
    let max_amt =
      let sender_balance = Balance.to_amount sender.balance in
      let receiver_capacity =
        Amount.(max_int - Balance.to_amount receiver.balance)
      in
      Amount.min sender_balance
        (Option.value ~default:sender_balance receiver_capacity)
    in
    let%map amount = Amount.(gen_incl zero max_amt) in
    make_txn ~sender:sender.pk ~receiver:receiver.pk amount

  let gen_account_pair_and_txn =
    let open Quickcheck in
    let open Generator.Let_syntax in
    let open Helpers in
    let%bind sender =
      Generator.filter ~f:Test_account.non_empty Test_account.gen
    in
    let%bind receiver = Test_account.gen in
    let max_amt =
      let sender_balance = Balance.to_amount sender.balance in
      let receiver_capacity =
        Amount.(max_int - Balance.to_amount receiver.balance)
      in
      Amount.min sender_balance
        (Option.value ~default:sender_balance receiver_capacity)
    in
    let%map amount = Amount.(gen_incl zero max_amt) in
    let txn = make ~sender:sender.pk ~receiver:receiver.pk amount in
    ((sender, receiver), txn)
end

module Single = struct
  let make ~account amount =
    object
      method account : Public_key.Compressed.t = account

      method amount : Amount.Signed.t = amount

      method updates =
        let open Monad_lib.State.Let_syntax in
        let open Account_update in
        let%map body = update_body ~account amount in
        [ update { body; authorization = dummy_auth } ]
    end
end
