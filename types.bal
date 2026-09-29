// Sizing and expiry for one in-memory cache; times are in seconds.
type CacheSettings record {|
    int capacity;
    decimal maxAge;
    decimal cleanupInterval;
    float evictionFactor = 0.2;
|};

type VersionsResponse record {|
    string[] versions;
|};

// Metadata for one package version resolved from Central.
type VersionMetadata record {|
    string balaURL;
    string digest; // OCI format: "sha256:<hex>"
    string platform;
    string distributionVersion;
    boolean isDeprecated;
    string deprecateMessage;
    string[] modules; // empty if Central does not report them
|};

// Source of a version-index blob; distribution is "" for the unscoped `latest` index.
type IndexSource record {|
    string org;
    string name;
    string distribution;
|};

// Built version manifest cached per "org/name/version".
type VersionManifest record {|
    string manifestText;
    string manifestDigest; // sha256 of manifestText
    string layerDigest;    // digest of the bala layer
    int layerSize;         // byte size of the bala layer
|};

type ReferrerInfo record {|
    string manifestDigest;
    int manifestSize;
|};

// Maps a version manifest digest back to its package key and byte size for referrers lookups.
type SubjectManifestInfo record {|
    string metaKey;
    int size;
|};

type ResolutionPackageRequest record {|
    string org;
    string name;
    string 'version;
    string mode;
|};

type PackageResolutionRequest record {|
    ResolutionPackageRequest[] packages;
|};

type DependencyNode record {
    string org;
    string name;
    string 'version;
    DependencyNode[] dependencies = [];
};

type ResolvedPackage record {
    string org;
    string name;
    string 'version;
    DependencyNode[] dependencyGraph = [];
};

type PackageResolutionResponse record {
    ResolvedPackage[] resolved = [];
};
