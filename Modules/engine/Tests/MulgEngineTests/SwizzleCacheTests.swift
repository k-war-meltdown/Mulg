import Foundation
import ObjectiveC
import Testing
import MulgEngineHooks

/// The original each class had: its index, read from the class name ("MulgCacheFixture<index>").
private let fixtureOriginal: @convention(c) (AnyObject, Selector) -> Int = { object, _ in
    guard let cls = object_getClass(object) else { return -1 }
    return Int(NSStringFromClass(cls).dropFirst("MulgCacheFixture".count)) ?? -1
}

/// One shared hook for every fixture class: its own class's original plus 1000.
private let fixtureHook: @convention(c) (AnyObject, Selector) -> Int = { object, selector in
    let replacement = unsafeBitCast(fixtureHook, to: IMP.self)
    guard let cls = object_getClass(object), let original = mulg_swizzle_original(cls, selector, replacement) else { return -1 }
    return unsafeBitCast(original, to: (@convention(c) (AnyObject, Selector) -> Int).self)(object, selector) + 1000
}

@Suite("Original-method cache")
struct SwizzleCacheTests {
    /// Twenty classes exceed the per-thread cache capacity. Every call must still reach its
    /// own class's original, however the calls interleave or replace a cached entry.
    @Test("Many classes sharing one hook each still reach their own original")
    func collidingLinesNeverMixClasses() throws {
        let selector = NSSelectorFromString("mulgCacheValue")
        let replacement = unsafeBitCast(fixtureHook, to: IMP.self)
        var classes: [AnyClass] = []
        for index in 0..<20 {
            let name = "MulgCacheFixture\(index)"
            // A class name may exist from an earlier run in the same process; a fresh pair otherwise.
            let cls: AnyClass
            if let existing = NSClassFromString(name) { cls = existing } else {
                let made = try #require(objc_allocateClassPair(NSObject.self, name, 0))
                class_addMethod(made, selector, unsafeBitCast(fixtureOriginal, to: IMP.self), "q@:")
                objc_registerClassPair(made)
                cls = made
            }
            let result = mulg_swizzle_instance_owned("test:cache", cls, selector, replacement, nil)
            #expect(result == .replaced, "\(name)")
            classes.append(cls)
        }
        let objects: [NSObject] = try classes.map { try #require($0 as? NSObject.Type).init() }
        for round in 0..<5 {
            // Forwards, then backwards, then every third: the same lines are reused by different classes.
            let order = round % 2 == 0 ? Array(objects.indices) : Array(objects.indices.reversed())
            for index in order + stride(from: 0, to: objects.count, by: 3) {
                let object = objects[index]
                let implementation = try #require(class_getMethodImplementation(object_getClass(object), selector))
                let call = unsafeBitCast(implementation, to: (@convention(c) (AnyObject, Selector) -> Int).self)
                #expect(call(object, selector) == 1000 + index, "class \(index), round \(round)")
            }
        }
    }

    @Test("An unknown class or replacement has no original, and is not cached as one")
    func unknownHasNoOriginal() {
        let selector = NSSelectorFromString("mulgCacheValue")
        let unrelated: @convention(c) (AnyObject, Selector) -> Int = { _, _ in 0 }
        #expect(mulg_swizzle_original(NSObject.self, selector, unsafeBitCast(unrelated, to: IMP.self)) == nil)
        #expect(mulg_swizzle_original(NSObject.self, selector, unsafeBitCast(unrelated, to: IMP.self)) == nil)
    }

    @Test("Publishing an ancestor hook invalidates a cached inherited original")
    func inheritedOriginalRefreshesAfterInstallation() throws {
        let selector = NSSelectorFromString("mulgCacheInheritedValue")
        let original: @convention(c) (AnyObject, Selector) -> Int = { _, _ in 17 }
        let replacement = unsafeBitCast(fixtureHook, to: IMP.self)
        let parent = try #require(objc_allocateClassPair(NSObject.self, "MulgCacheAncestorFixture", 0))
        class_addMethod(parent, selector, unsafeBitCast(original, to: IMP.self), "q@:")
        objc_registerClassPair(parent)
        let child = try #require(objc_allocateClassPair(parent, "MulgCacheDescendantFixture", 0))
        objc_registerClassPair(child)

        // Misses before installation must not survive a later successful hook installation.
        #expect(mulg_swizzle_original(child, selector, replacement) == nil)
        #expect(mulg_swizzle_instance_owned("test:cache:ancestor", parent, selector, replacement, nil) == .replaced)
        for _ in 0..<20 {
            #expect(mulg_swizzle_original(child, selector, replacement) == unsafeBitCast(original, to: IMP.self))
        }

        // An unrelated publication expires both ways without changing the inherited answer.
        let otherSelector = NSSelectorFromString("mulgCacheAdditionalValue")
        class_addMethod(parent, otherSelector, unsafeBitCast(original, to: IMP.self), "q@:")
        #expect(mulg_swizzle_instance_owned("test:cache:additional", parent, otherSelector, replacement, nil) == .replaced)
        #expect(mulg_swizzle_original(child, selector, replacement) == unsafeBitCast(original, to: IMP.self))
        #expect(mulg_swizzle_original(child, otherSelector, replacement) == unsafeBitCast(original, to: IMP.self))
    }
}
