import Foundation

// Compile this file with the exact AssistantIntentRouter.swift being measured:
// swiftc -O -parse-as-library KestrelWebKit/AssistantIntentRouter.swift \
//   scripts/benchmark-intent-router.swift -o /private/tmp/kestrel-router-benchmark
// This stub satisfies the unused model entry point. The benchmark measures
// deterministic routing only; it makes no model, network or Keychain request.
enum AppleLocalModelProvider {
    static func classifyIntent(_ prompt: String) async -> AssistantIntent? { nil }
}

@main
struct IntentRouterBenchmark {
    static let prompts = [
        "Explain this in simple terms", "Find current reviews of this laptop",
        "Click the download button on this page", "What is the weather in London?",
        "Write a script that fetches the weather", "Tell me about reusable rockets",
        "Can you find and add a book to my basket on the website?",
        "How do I add a book to my basket?", "Can you find me images of Falcon Heavy?",
        "Could you show me some photos of the aurora, please?", "Find falcon heavy images",
        "latest phone price", "what is the time cost of quicksort", "look up phone reviews",
        "Explain 👩🏽‍💻 café and 東京", "", String(repeating: "ordinary prose ", count: 80)
    ]

    static func exercise(_ prompt: String) -> String {
        let decisions: [AssistantIntent?] = [nil, .answer, .search, .cursor, .imageSearch]
        return decisions.map { AssistantIntentRouter.resolve(prompt, modelDecision: $0).rawValue }.joined(separator: ",")
            + "|" + (AssistantIntentRouter.imageSearchQuery(from: prompt) ?? "")
            + "|" + AssistantIntentRouter.strippingSearchInstruction(prompt)
            + "|" + AssistantIntentRouter.localisedSearchQuery(prompt, regionName: "United Kingdom")
    }

    static func main() throws {
        let expected = prompts.map(exercise) // warm lazy caches before timing
        var timings: [Double] = []
        var checksum = 0
        for _ in 0..<5 {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<20 {
                for prompt in prompts { checksum += exercise(prompt).utf8.count }
            }
            timings.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        let result: [String: Any] = [
            "samples_ms": timings, "median_ms": timings.sorted()[timings.count / 2],
            "corpus": expected, "checksum": checksum,
            "prompts_per_sample": prompts.count * 20,
            "note": "Optimised standalone synthetic routing benchmark; not end-to-end assistant latency"
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
        print(String(decoding: data, as: UTF8.self))
    }
}
