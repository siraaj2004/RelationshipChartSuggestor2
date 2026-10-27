import Foundation

/// Lexicon-based detection for Roman Telugu / Roman Urdu / English and mixes.
/// This is intentionally conservative: function-word evidence must appear, and
/// a tie returns `.unknown` rather than a confident wrong label. The backend
/// re-detects with the same word lists (see Backend/app/conversations.py — keep in sync).
public enum LanguageDetector {

    static let teluguMarkers: Set<String> = [
        "nenu","nuuvu","nuvvu","meeru","vaadu","aame","adi","idi","ela","enti","enduku",
        "ekkada","eppudu","avunu","avuna","kaadu","ledu","ledhu","undi","undhi","vundhi","unna","chesa","chestunna","ra",
        "rey","raa","anna","annayya","akka","cheli","baaga","bagunna","bagunnava","chaala","konchem","ippudu","repu","ninna","monna",
        "tinnaava","velta","vastunna","ayyindi","kaavali","kavali","cheppu","cheppandi","choodu","chudu","vinava","vinu",
        "emiti","emi","em","entha","evaru","evadu","aithe","kani","mari","inka","ippude","akkada","ikkada","naaku","naku","neeku","neku",
        "manam","memu","appudu","tarvata","mundu","bangaram","istam","prema","chey","amma","nanna","babu"
    ]
    static let urduMarkers: Set<String> = [
        "mein","tum","aap","hai","hain","nahi","kya","kyun","kyu","kahan","kab","kaise",
        "mera","meri","tumhara","uska","usko","isko","kisko","yeh","woh","bhi","aur","lekin","phir","abhi",
        "kal","aaj","bohat","bahut","acha","accha","theek","karo","karke","raha","rahi",
        "tha","thi","gaya","aaya","bolo","suno","sun","dekho","dekh","yaar","bhai","shukriya",
        "inshallah","mashallah","allah","kaisa","kaisi","ho","na","toh","matlab",
        "haan","han","ji","batao","bata","kuch","kabhi","chalo","zaroor","bilkul","bas",
        "mujhe","tujhe","jao","aao","ruk","samajh","dil","yaad","hamesha","jaan"
    ]
    static let englishMarkers: Set<String> = [
        "the","is","are","was","were","you","your","yours","what","when","where","why",
        "how","and","but","that","this","with","for","have","had","will","would","can",
        "could","should","did","do","does","going","want","really","because","about"
    ]

    public static func detect(texts: [String]) -> DetectedLanguage {
        let joined = texts.joined(separator: " ").lowercased()
        let tokens = joined.split { !$0.isLetter && $0 != "'" }.map(String.init)
        // Single-token fix (2026-10-27): a lone Roman word like "haan"
        // or "avuna" used to fall through to .english, so a Select
        // Message reply came back in English for a Roman chat. One
        // token with no marker evidence is .unknown, not English —
        // the caller then falls back to the previous chat language.
        guard !tokens.isEmpty else { return .unknown }
        if tokens.count == 1 {
            if teluguMarkers.contains(tokens[0]) { return .romanTelugu }
            if urduMarkers.contains(tokens[0]) { return .romanUrdu }
            if englishMarkers.contains(tokens[0]) { return .english }
            return .unknown
        }

        let te = tokens.filter { teluguMarkers.contains($0) }.count
        let ur = tokens.filter { urduMarkers.contains($0) }.count
        let en = tokens.filter { englishMarkers.contains($0) }.count
        let total = max(tokens.count, 1)
        let enRatio = Double(en) / Double(total)

        if te > 0 && ur > 0 { return enRatio > 0.15 ? (te >= ur ? .mixedTeluguEnglish : .mixedUrduEnglish) : (te >= ur ? .romanTelugu : .romanUrdu) }
        if te > 0 { return en >= 2 && enRatio > 0.12 ? .mixedTeluguEnglish : .romanTelugu }
        if ur > 0 { return en >= 2 && enRatio > 0.12 ? .mixedUrduEnglish : .romanUrdu }
        if en > 0 { return .english }
        // No function-word evidence: short romanised text is ambiguous by nature.
        return .unknown
    }

    public static func detect(context: ConversationContext) -> DetectedLanguage {
        detect(texts: context.messages.map(\.text))
    }
}
