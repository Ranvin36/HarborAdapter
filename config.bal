import ballerina/cache;

// Defaults match the previous hardcoded values; override in Config.toml.

configurable int port = 8080;

// Ballerina Central API
configurable string centralUrl = "https://api.central.ballerina.io";
configurable decimal centralTimeout = 30;
configurable int centralMaxActiveConnections = 100;
configurable int centralMaxIdleConnections = 20;
configurable decimal centralPoolWaitTime = 30;

// Bala CDN (HEAD requests for bala sizes)
configurable decimal balaCdnTimeout = 30;

// In-memory caches; maxAge and cleanupInterval are in seconds.
configurable CacheSettings blobCacheSettings = {capacity: 200, maxAge: 600.0, cleanupInterval: 60.0};
configurable CacheSettings blobSourcesSettings = {capacity: 500, maxAge: 600.0, cleanupInterval: 60.0};
configurable CacheSettings versionMetaCacheSettings = {capacity: 1000, maxAge: 1800.0, cleanupInterval: 120.0};
configurable CacheSettings versionsListCacheSettings = {capacity: 500, maxAge: 300.0, cleanupInterval: 60.0};
configurable CacheSettings depGraphMetaCacheSettings = {capacity: 1000, maxAge: 1800.0, cleanupInterval: 120.0};
configurable CacheSettings manifestsByDigestSettings = {capacity: 1000, maxAge: 1800.0, cleanupInterval: 120.0};
configurable CacheSettings subjectManifestSourcesSettings = {capacity: 1000, maxAge: 1800.0, cleanupInterval: 120.0};

isolated function newCache(CacheSettings settings) returns cache:Cache {
    return new (capacity = settings.capacity, evictionFactor = settings.evictionFactor,
            defaultMaxAge = settings.maxAge, cleanupInterval = settings.cleanupInterval);
}
