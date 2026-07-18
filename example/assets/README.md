# Audio fixtures

License-clean test audio generated with Apple's `say` (no third-party rights):

    say -v Samantha --file-format=WAVE --data-format=LEI16@16000 -o hello.wav "Hello world, this is a test of on device speech recognition."
    say -v Daniel   --file-format=WAVE --data-format=LEI16@16000 -o speaker2.wav "And this is a second speaker replying in the conversation."
    # silence.wav: 2 seconds of zeros, 16 kHz mono 16-bit (see integration test setup)

All files are 16 kHz mono 16-bit PCM.
