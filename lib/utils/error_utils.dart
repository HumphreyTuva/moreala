String friendlyErrorMessage(Object e) {
  final message = e.toString();

  if (message.contains('SocketException') ||
      message.contains('Failed host lookup') ||
      message.contains('Network is unreachable') ||
      message.contains('Connection failed') ||
      message.contains('Connection timed out')) {
    return 'You appear to be offline. Check your internet connection and try again.';
  }

  if (message.contains('TimeoutException')) {
    return 'That took too long to respond. Check your connection and try again.';
  }

  return 'Something went wrong. Please try again.';
}