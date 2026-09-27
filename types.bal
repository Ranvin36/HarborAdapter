type VersionsResponse record {|
    string[] versions;
|};

// Version metadata resolved from Ballerina Central for one package version: the bala download
// URL, the platform/distribution it was published for, and its current deprecation status — used
// to annotate the OCI manifest so a Ballerina client can filter compatible versions and surface
// deprecation warnings without downloading the bala.
type VersionMetadata record {|
    string balaURL;
    string platform;
    string distributionVersion;
    boolean isDeprecated;
    string deprecateMessage;
|};

// Identifies a built dependency-graph referrer artifact: its own manifest digest and byte size,
// as needed for a referrers-index entry (OCI Distribution Spec `GET /v2/{name}/referrers/{digest}`).
type ReferrerInfo record {|
    string manifestDigest;
    int manifestSize;
|};

// Maps a version manifest's own (self) digest back to the package it identifies, plus that
// manifest's byte size — both are needed to answer `GET /v2/{name}/referrers/{digest}` and to
// populate the `subject` descriptor of a referrer manifest, since that query only carries a digest.
type SubjectManifestInfo record {|
    string metaKey;
    int size;
|};

// Central's `POST /registry/packages/resolve-dependencies` request/response shapes
// (mirrors org.ballerinalang.central.client.model.PackageResolutionRequest/Response).
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
