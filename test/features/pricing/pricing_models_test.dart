import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/features/pricing/model/pricing_models.dart';

void main() {
  test('parses four base plans in server order', () {
    final response = PricingResponse.parse({
      'ok': true,
      'data': {
        'server_time': '2026-06-08T12:52:22.752Z',
        'plans': [
          _plan(id: 1, code: '1', months: 1, amount: 15000),
          _plan(id: 2, code: '3', months: 3, amount: 40000),
          _plan(id: 3, code: '6', months: 6, amount: 70000),
          _plan(id: 4, code: '12', months: 12, amount: 120000),
        ],
      },
    });

    expect(response.ok, isTrue);
    expect(response.data!.plans.map((plan) => plan.code), ['1', '3', '6', '12']);
    expect(response.data!.plans.last.finalAmountMinor, 120000);
  });

  test('parses common discount without calculating final price locally', () {
    final plan = PricingPlan.parse(_plan(id: 2, code: '3', months: 3, amount: 25000, base: 40000, discount: 15000));

    expect(plan.baseAmountMinor, 40000);
    expect(plan.discountAmountMinor, 15000);
    expect(plan.finalAmountMinor, 25000);
  });

  test('parses personalized fixed price from personalized field', () {
    final plan = PricingPlan.parse({
      ..._plan(id: 2, code: '3', months: 3, amount: 25000, base: 40000, discount: 15000),
      'personalized': true,
      'applied_rule': {'source': 'user', 'id': 12, 'type': 'fixed_price'},
    });

    expect(plan.personalized, isTrue);
    expect(plan.appliedRule!.type, 'fixed_price');
  });

  test('formats kopecks as rubles', () {
    expect(formatMinorCurrency(15000, 'RUB', 'ru_RU'), contains('150'));
    expect(formatMinorCurrency(15050, 'RUB', 'ru_RU'), contains('150,50'));
  });
}

Map<String, dynamic> _plan({
  required int id,
  required String code,
  required int months,
  required int amount,
  int? base,
  int discount = 0,
}) {
  return {
    'plan_id': id,
    'code': code,
    'months': months,
    'name': '$months months',
    'currency': 'RUB',
    'base_amount_minor': base ?? amount,
    'discount_amount_minor': discount,
    'final_amount_minor': amount,
    'personalized': false,
    'applied_rule': null,
  };
}
