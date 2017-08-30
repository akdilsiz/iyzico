defmodule Iyzico.Iyzipay do
  @moduledoc """
  A module containing payment related functions.

  ## Making a payment

  In order to process a payment, one needs to create a `Iyzico.PaymentRequest` struct, which consists of a payment card,
  a buyer, two seperate addresses for shipping and billing and basket information (aka *items*).
  ```
  payment_request =
    %PaymentRequest{
      locale: @current_locale,
      conversation_id: "123456789",
      price: "0.5",
      paid_price: "0.7",
      currency: :try,
      basket_id: "B67832",
      payment_channel: :web,
      payment_group: :product,
      payment_card: card,
      installment: 1,
      buyer: buyer,
      shipping_address: shipping_address,
      billing_address: billing_address,
      basket_items: [
        binocular_item,
        game_item
      ]
    }
  ```

  With that `Iyzico.PaymentRequest`, it is straightforward to process the request.

  ```
  {:ok, payment, metadata} = process_payment_req(payment_request)
  ```
  """
  import Iyzico.Client

  alias Iyzico.Payment
  alias Iyzico.Transaction
  alias Iyzico.ConvertedPayout
  alias Iyzico.Metadata
  alias Iyzico.Card
  alias Iyzico.CardReference

  @doc """
  Processes the given payment request on the remote API.

  ## 3D Secure support

  To enhance authenticity of a transaction, *3D Secure* could be used optionally, although some associations might
  require the use of *3D Secure* explicitly.
  Performing *3D Secure* based transaction is achieved by supplying a callback URL to the function.

  ## Options

  - `:api_key`: API key to be used in authentication, optional. Configuration is used instead if not supplied.

  - `:api_secret`: API secret key to be used in authentication. Configuration is used instead if not supplied.

  - `:secure_callback_url`: Callback URL to be used in *3D Secure* workflow, optional.
  *3D Secure* is not used if not supplied.
  """
  @spec process_payment_req(Iyzico.PaymentRequest.t, Keyword.t) ::
    {:ok, Iyzico.Payment.t, Iyzico.Metadata.t} |
    {:error, atom}
  def process_payment_req(payment_request = %Iyzico.PaymentRequest{}, opts \\ []) do
    callback_url = Keyword.get(opts, :secure_callback_url)
    payment_request = put_callback_url(payment_request, callback_url)

    {url, payment_request} =
      if is_nil(callback_url) do
        {"/payment/auth", payment_request}
      else
        {"/payment/3dsecure/auth", Map.put(payment_request, :callback_url, callback_url)}
      end

    case request([], :post, url_for_path(url), [], payment_request, opts) do
      {:ok, resp} ->
        transactions =
          resp["itemTransactions"]
          |> Enum.map(fn x ->
            %Transaction{
              blockage_rate: x["blockageRate"],
              merchant_blockage_amount: x["blockageRateAmountMerchant"],
              submerchant_blockage_amount: x["blockageRateAmountSubMerchant"],
              resolution_date: x["blockageResolvedDate"],
              converted_payout: %ConvertedPayout{
                merchant_blockage_amount: x["convertedPayout"]["blockageRateAmountMerchant"],
                submerchant_blockage_amount: x["convertedPayout"]["blockageRateAmountSubMerchant"],
                currency: x["convertedPayout"]["currency"],
                commission_fee: x["convertedPayout"]["iyziCommissionFee"],
                commission_amount: x["convertedPayout"]["iyziCommissionRateAmount"],
                conversion_rate: x["convertedPayout"]["iyziConversionRate"],
                conversion_cost: x["convertedPayout"]["iyziConversionRateAmount"],
                merchant_payout_amount: x["convertedPayout"]["merchantPayoutAmount"],
                paid_price: x["convertedPayout"]["paidPrice"],
                submerchant_payout_amount: x["convertedPayout"]["subMerchantPayoutAmount"]
              },
              item_id: x["itemId"],
              commission_amount: x["iyziCommissionRateAmount"],
              commission_fee: x["iyziCommissionFee"],
              merchant_commission_rate: x["merchantCommissionRate"],
              merchant_commission_amount: x["merchantCommissionRateAmount"],
              merchant_payout_amount: x["merchantPayoutAmount"],
              paid_price: x["paidPrice"],
              id: x["paymentTransactionId"],
              price: x["price"],
              submerchant_payout_amount: x["subMerchantPayoutAmount"],
              submerchant_payout_rate: x["subMerchantPayoutRate"],
              submerchant_price: x["subMerchantPrice"],
              transaction_status: Transaction.to_transaction_status(x["transactionStatus"])}
            end)

        payment =
          %Payment{
            basket_id: resp["basketId"],
            bin_id: resp["binNumber"],
            card_ref: %CardReference{
              assoc: Card.get_card_assoc(resp["cardAssociation"]),
              family: Card.get_card_family(resp["cardFamily"]),
              type: Card.get_card_type(resp["cardType"]),
              alias: payment_request.payment_card.registration_alias,
              user_key: resp["cardUserKey"],
              token: resp["cardToken"],
              card: payment_request.payment_card,
              email: payment_request.buyer.email
            },
            conversation_id: resp["conversationId"],
            currency: resp["currency"] |> String.downcase() |> String.to_atom(),
            fraud_status: Payment.to_fraud_status(resp["fraudStatus"]),
            installment: resp["installment"],
            transactions: transactions,
            commission_fee: resp["iyziCommissionFee"],
            commission_amount: resp["iyziCommissionRateAmount"],
            last_four_digits: resp["lastFourDigits"],
            merchant_commission_rate: resp["merchantCommissionRate"],
            merchant_commission_amount: resp["merchantCommissionRateAmount"],
            paid_price: resp["paidPrice"],
            price: resp["price"],
            id: resp["paymentId"]}

        metadata =
          %Metadata{
            system_time: resp["systemTime"],
            succeed?: resp["status"] == "success",
            phase: resp["phase"],
            locale: resp["locale"],
            auth_code: resp["authCode"]}

        {:ok, payment, metadata}
      any ->
        any
     end
  end

  @doc """
  Same as `process_payment_req/1`, but raises an `Iyzico.PaymentProcessingError` exception in case of failure.
  Otherwise returns successfully processed payment.
  """
  def process_payment_req!(payment = %Iyzico.PaymentRequest{}, opts \\ []) do
    case process_payment_req(payment, opts) do
      {:ok, payment, metadata} ->
        {payment, metadata}
      {:error, code} ->
        raise Iyzico.PaymentProcessingError, code: code
    end
  end

  defp put_callback_url(payment_request, callback_url) do
    if not is_nil(callback_url) do
      Map.put(payment_request, :callback_url, callback_url)
    else
      payment_request
    end
  end
end