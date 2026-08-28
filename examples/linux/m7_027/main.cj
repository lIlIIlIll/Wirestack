package wirestack_m7_027_examples

main(): Int64 {
    try {
        runHttpExamples()
        runTransportTlsExample()
        0
    } catch (error: Exception) {
        eprintln("M7-027 example failed: ${error}")
        1
    }
}

