// test/data/device_clock_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mayday/data/time/device_clock.dart';
import 'package:mayday/data/identity/sequence_counter.dart';
import 'package:mayday/data/models/logical_clock.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('DeviceClock — Lamport semantics (§4)', () {
    test('tickForSend increments monotonically', () async {
      final clock = const DeviceClock('device-a');
      expect((await clock.tickForSend()).counter, 1);
      expect((await clock.tickForSend()).counter, 2);
      expect((await clock.tickForSend()).counter, 3);
    });

    test('observeReceive jumps to max(local, remote) + 1', () async {
      final clock = const DeviceClock('device-a');
      await clock.tickForSend(); // local = 1

      // Hearing a much higher remote counter pulls us forward.
      final afterHigh = await clock.observeReceive(
        const LogicalClock(deviceId: 'device-b', counter: 50),
      );
      expect(afterHigh.counter, 51);

      // Hearing a lower one does not drag us back.
      final afterLow = await clock.observeReceive(
        const LogicalClock(deviceId: 'device-b', counter: 2),
      );
      expect(afterLow.counter, 52);
    });

    test('a send after a receive orders strictly later than what was heard',
        () async {
      final clock = const DeviceClock('device-a');
      final heard = const LogicalClock(deviceId: 'device-b', counter: 10);
      await clock.observeReceive(heard);

      final mine = await clock.tickForSend();
      expect(mine.compareTo(heard), greaterThan(0));
    });

    test('peek does not advance the clock', () async {
      final clock = const DeviceClock('device-a');
      await clock.tickForSend();
      expect((await clock.peek()).counter, 1);
      expect((await clock.peek()).counter, 1);
    });
  });

  group('SequenceCounter is NOT the Lamport clock', () {
    test('mesh traffic moves the Lamport clock but never the sequence counter',
        () async {
      final clock = const DeviceClock('device-a');

      expect(await SequenceCounter.getNextSequence(), 1);
      await clock.tickForSend();

      // A burst of mesh traffic from a device far ahead of us.
      await clock.observeReceive(
        const LogicalClock(deviceId: 'device-b', counter: 500),
      );

      // The Lamport clock followed it...
      expect((await clock.peek()).counter, 501);

      // ...but the next claim this device originates is still sequence 2.
      // If these were one counter, this would be 502 and the SOS id for
      // this device's second claim would depend on unrelated mesh traffic.
      expect(await SequenceCounter.getNextSequence(), 2);
    });
  });
}
