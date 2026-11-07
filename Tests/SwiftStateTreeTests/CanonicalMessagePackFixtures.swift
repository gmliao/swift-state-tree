// Expected bytes for CanonicalMessagePackTests, computed by a separate reference encoder written
// from the format rules (`Tools/CanonicalMessagePack/reference.py`, not by CanonicalMessagePack), so
// a test failure is a disagreement with the rules, not with an earlier run. A change here is a
// format change.

enum CanonicalMessagePackFixtures {
    /// `edgeSetCommittedBytes`'s `EdgeSet`, encoded.
    static let edgeSetHex =
        "8aa5646174657393b4313937302d30312d30315430303a30303a30305ab4313936392d31322d33315432333a35393a35385ab4323032332d31312d31345432323a31333a32305aa7646f75626c657397cb3fb999999999999acb8000000000000000cb7ff0000000000000cbfff0000000000000cb7ff8000000000000cb7e37e43c8800759ccb0000000000000001a5656d70747990a8656d7074794d617080a6666c6f61747393cb3fb99999a0000000cb3ff8000000000000cb7ff8000000000000a4696e747398007fcc80ffe0d0dfd38000000000000000cf7fffffffffffffffa46b65797385a005a14201a16102a2c3a903a4f09f988004a66e657374656482a16180a17a81a1799101a36e666481a365cc8101a475696e74cfffffffffffffffff"

    /// `Examples/GameDemo/reevaluation-records/3-hero-defense.json`, encoded.
    static let heroDefenseRecordByteCount = 73575
    static let heroDefenseRecordSHA256 = "43b6713e4dc938bb3d0d158645ad868e6ef4f9b0f7c8c85fab5c92b8b71d8f39"
}
