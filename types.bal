type VersionsResponse record {|
    string[] versions;
|};

enum DigestType {
    VERSIONS,
    BALA
}

// Metadata stored per digest to enable on-demand bala download and caching
type BalaMetadata record {|
    string org;
    string name;
    string version;
    string balaURL;
    byte[]? cachedBytes = ();
|};
