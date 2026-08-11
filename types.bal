type VersionsResponse record {|
    string[] versions;
|};

// Identifies a built dependency-graph referrer artifact: its own manifest digest and byte size,
// as needed for a referrers-index entry (OCI Distribution Spec `GET /v2/{name}/referrers/{digest}`).
type ReferrerInfo record {|
    string manifestDigest;
    int manifestSize;
|};
