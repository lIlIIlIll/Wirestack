package wirestack.http

/** Explicit policy for requests already admitted to a superseded configuration. */
public enum HttpConfigurationRotation {
    /** Finish admitted exchanges, drain old connections, and route future admissions to the new snapshot. */
    | Graceful
    /** Cancel old-generation work and abort old connections after atomically publishing the new snapshot. */
    | SecurityReplacement
}
