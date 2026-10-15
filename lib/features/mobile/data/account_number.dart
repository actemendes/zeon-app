final _accountNumberPattern = RegExp(r'^[1-9][0-9]{0,15}$');
final _maxAccountNumber = BigInt.parse('9007199254740991');

/// Whether [value] is a canonical account number that the API can represent
/// exactly. Callers decide whether to trim user input; this never rewrites it.
bool isValidAccountNumber(String value) {
  final match = _accountNumberPattern.firstMatch(value);
  if (match == null || match.end != value.length) return false;
  return BigInt.parse(value) <= _maxAccountNumber;
}
