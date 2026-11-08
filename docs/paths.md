# The path layer

A typed thing **owns its path**; nobody else restates it. Production and test differ only by the injected root.

## Owners

```swift
import CoreKit

enum Tree {
    static let flows = VirtualNode("flows")
    static let state = VirtualNode("state")
}

/// A single resource: the static placement is the whole declaration.
struct PlansLedger: VirtualPathOwning {
    static let placement = VirtualPlacement(node: Tree.state, name: "plans.json")
}

/// An id-dependent one: the id is a folder AND part of the file name.
struct FlowMetadata: VirtualPathOwning {
    static let placement = VirtualPlacement(node: Tree.flows, name: "metadata.json")
    let flowID: String

    func location() throws(VirtualPathError) -> VirtualPath {
        VirtualPath(try PathSegment(flowID), try PathSegment("\(flowID)-metadata.json"))
    }
}
```

The static `placement` (node + name) is what the registry keys on; the instance `location()` is the concrete path below the node.
A node is a value, not a case of a closed enum, so a project defines its own scope kinds and the root of any of them can be moved by settings.

## Segments cannot climb

`VirtualPath` is a list of `PathSegment`s and nothing else: no separator, no root, no OS. A `PathSegment` is validated when it is built
(non-empty, not `.`/`..`, at most 255 UTF-8 bytes, no control character, none of `<>:"|?*`, no separator of any platform, no leading or
trailing whitespace, no trailing dot), so an id like `../../x` is refused at the owner's `PathSegment(flowID)`, before any URL exists.
Literals (`"plans.json"`) trap if invalid; data goes through the throwing `PathSegment(_:)` or `PathSegment.slug(from:)`.

## Registry, layer, containment

```swift
func demo(root: URL) throws {
    let registry = try VirtualPathRegistry([PlansLedger.self, FlowMetadata.self])   // refuses two kinds on one placement
    let layer = try PathLayer(root: root, registry: registry)

    let ledger = try layer.url(for: PlansLedger())                // <root>/state/plans.json
    let meta = try layer.url(for: FlowMetadata(flowID: "7f3a"))   // <root>/flows/7f3a/7f3a-metadata.json
    let address = try layer.address(for: FlowMetadata(flowID: "7f3a"), bucket: "evidence", nodeID: "mac-a")
    _ = (ledger, meta, address.rendered())
}
```

- An owner that was never added to the registry is refused by name: no second, invisible tree.
- Resolution is resolve-only: nothing is created. The writer creates the directory.
- `url(for:)` checks containment (`PathContainment`), resolving symlinks on both sides; a link that leaves the node, or a dangling link, is refused.
- The same components render as a local file (`url(for:)`) or as an object-store address (`address(for:bucket:nodeID:)`).
- `PathLayerConfiguration` builds a layer from settings strings and refuses a relative, blank or `~`-prefixed root. CoreKit holds no default root: the host injects it.
- `OwnedResourceStore<Model>(owner, paths:)` reads and writes one typed JSON document at the owner's location through `CacheRepository`.

## Test root

`TestRunRoot(base:branch:correlationID:target:)` is `<base>/.tests/<branch-slug>/<correlation-id>/<target>/`. The correlation id is the
identity (never slugged); the branch is only a readable grouping. Prod and test register the same `PathLayer` over different roots:

```swift
func testContainer(base: URL) throws -> Container {
    let run = try TestRunRoot(base: base, branch: "feature/x", correlationID: "run-01", target: "MyTests")
    let container = Container(name: "test")
    try DIAssemblyResourcePathsMock(run: run, owners: [PlansLedger.self]).assemble(container: container, environment: .mock)
    return container
}
```

In CoreKit's own tests, `TestScratch` / `TestSandbox` (in `CoreKitTestSupport`) mint the scratch directories.
