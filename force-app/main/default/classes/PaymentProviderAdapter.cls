public interface PaymentProviderAdapter {
  PaymentCapabilityResult initializePayment(PaymentCapabilityRequest request);
  PaymentCapabilityResult executePayment(PaymentCapabilityRequest request);
  PaymentCapabilityResult recoverPayment(PaymentCapabilityRequest request);
  PaymentCapabilityResult refundPayment(PaymentCapabilityRequest request);
}