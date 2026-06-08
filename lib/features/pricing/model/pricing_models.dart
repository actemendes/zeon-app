import 'package:intl/intl.dart';

class PricingResponse {
  const PricingResponse({required this.ok, required this.data, this.error});

  final bool ok;
  final PricingData? data;
  final PricingApiError? error;

  factory PricingResponse.parse(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('pricing response is not an object');
    }
    final ok = json['ok'] == true;
    final data = json['data'];
    return PricingResponse(
      ok: ok,
      data: data is Map<String, dynamic> ? PricingData.parse(data) : null,
      error: json['error'] is Map<String, dynamic>
          ? PricingApiError.parse(json['error'] as Map<String, dynamic>)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'ok': ok,
    if (data != null) 'data': data!.toJson(),
    if (error != null) 'error': error!.toJson(),
  };
}

class PricingData {
  const PricingData({required this.plans, required this.serverTime});

  final List<PricingPlan> plans;
  final DateTime? serverTime;

  factory PricingData.parse(Map<String, dynamic> json) {
    final rawPlans = json['plans'];
    if (rawPlans is! List) {
      throw const FormatException('pricing plans are missing');
    }
    return PricingData(
      plans: rawPlans.whereType<Map<String, dynamic>>().map(PricingPlan.parse).toList(growable: false),
      serverTime: DateTime.tryParse(json['server_time']?.toString() ?? '')?.toUtc(),
    );
  }

  Map<String, dynamic> toJson() => {
    'plans': plans.map((plan) => plan.toJson()).toList(growable: false),
    if (serverTime != null) 'server_time': serverTime!.toIso8601String(),
  };
}

class PricingPlan {
  const PricingPlan({
    required this.planId,
    required this.code,
    required this.months,
    required this.name,
    required this.currency,
    required this.baseAmountMinor,
    required this.discountAmountMinor,
    required this.finalAmountMinor,
    required this.personalized,
    required this.appliedRule,
    this.bundledFallback = false,
  });

  final int planId;
  final String code;
  final int months;
  final String name;
  final String currency;
  final int baseAmountMinor;
  final int discountAmountMinor;
  final int finalAmountMinor;
  final bool personalized;
  final AppliedPricingRule? appliedRule;
  final bool bundledFallback;

  factory PricingPlan.parse(Map<String, dynamic> json) {
    final planId = _parseInt(json['plan_id'] ?? json['planId']);
    final code = (json['code'] ?? '').toString().trim();
    final months = _parseInt(json['months']);
    final name = (json['name'] ?? '').toString().trim();
    final currency = (json['currency'] ?? 'RUB').toString().trim().toUpperCase();
    final baseAmountMinor = _parseInt(json['base_amount_minor'] ?? json['baseAmountMinor']);
    final discountAmountMinor = _parseInt(json['discount_amount_minor'] ?? json['discountAmountMinor']);
    final finalAmountMinor = _parseInt(json['final_amount_minor'] ?? json['finalAmountMinor']);
    if (planId == null ||
        code.isEmpty ||
        months == null ||
        months <= 0 ||
        baseAmountMinor == null ||
        discountAmountMinor == null ||
        finalAmountMinor == null) {
      throw const FormatException('invalid pricing plan');
    }
    return PricingPlan(
      planId: planId,
      code: code,
      months: months,
      name: name.isEmpty ? '$months months' : name,
      currency: currency.isEmpty ? 'RUB' : currency,
      baseAmountMinor: baseAmountMinor,
      discountAmountMinor: discountAmountMinor,
      finalAmountMinor: finalAmountMinor,
      personalized: json['personalized'] == true,
      appliedRule: json['applied_rule'] is Map<String, dynamic>
          ? AppliedPricingRule.parse(json['applied_rule'] as Map<String, dynamic>)
          : null,
      bundledFallback: json['bundled_fallback'] == true || json['bundledFallback'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
    'plan_id': planId,
    'code': code,
    'months': months,
    'name': name,
    'currency': currency,
    'base_amount_minor': baseAmountMinor,
    'discount_amount_minor': discountAmountMinor,
    'final_amount_minor': finalAmountMinor,
    'personalized': personalized,
    'applied_rule': appliedRule?.toJson(),
    if (bundledFallback) 'bundled_fallback': true,
  };

  String formatFinalPrice([String? locale]) => formatMinorCurrency(finalAmountMinor, currency, locale);
  String formatBasePrice([String? locale]) => formatMinorCurrency(baseAmountMinor, currency, locale);
  String formatDiscount([String? locale]) => formatMinorCurrency(discountAmountMinor, currency, locale);
}

class AppliedPricingRule {
  const AppliedPricingRule({required this.source, required this.id, required this.type});

  final String source;
  final int? id;
  final String type;

  factory AppliedPricingRule.parse(Map<String, dynamic> json) {
    return AppliedPricingRule(
      source: (json['source'] ?? '').toString(),
      id: _parseInt(json['id']),
      type: (json['type'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toJson() => {'source': source, 'id': id, 'type': type};
}

class PricingApiError {
  const PricingApiError({required this.code, required this.message});

  final String code;
  final String message;

  factory PricingApiError.parse(Map<String, dynamic> json) {
    return PricingApiError(code: (json['code'] ?? '').toString(), message: (json['message'] ?? '').toString());
  }

  Map<String, dynamic> toJson() => {'code': code, 'message': message};
}

String formatMinorCurrency(int amountMinor, String currency, [String? locale]) {
  final symbolFormatter = NumberFormat.simpleCurrency(name: currency, locale: locale);
  final numberFormatter = NumberFormat.decimalPattern(locale);
  final major = amountMinor ~/ 100;
  final minor = amountMinor.abs() % 100;
  final amount = minor == 0
      ? numberFormatter.format(major)
      : '${numberFormatter.format(major)},${minor.toString().padLeft(2, '0')}';
  final symbol = symbolFormatter.currencySymbol;
  return symbol == currency ? '$amount $currency' : '$amount $symbol';
}

int? _parseInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}
