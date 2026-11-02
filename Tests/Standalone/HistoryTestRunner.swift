// A tiny assertion/runner adapter for the same XCTest cases, when only Apple's
// Command Line Tools are installed. No dependencies or user clipboard access.
import Foundation
import os

class HistoryTestCase {}
private var assertionFailures = 0

private struct UnwrapFailure: Error {}

private func fail(_ message: String, file: StaticString, line: UInt) {
    assertionFailures += 1
    print("FAIL \(file):\(line): \(message)")
}

func XCTFail(_ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    fail(message, file: file, line: line)
}

func XCTAssertEqual<T: Equatable>(_ actual: @autoclosure () throws -> T,
    _ expected: @autoclosure () throws -> T, _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line) {
    do {
        let a = try actual(), b = try expected()
        if a != b { fail("\(a) != \(b) \(message)", file: file, line: line) }
    } catch { fail("Unexpected error: \(error) \(message)", file: file, line: line) }
}

func XCTAssertEqual<T: FloatingPoint>(_ actual: @autoclosure () throws -> T,
    _ expected: @autoclosure () throws -> T, accuracy: T, _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line) {
    do {
        let a = try actual(), b = try expected()
        if a != b && !(abs(a - b) <= accuracy) {
            fail("\(a) != \(b) within \(accuracy) \(message)", file: file, line: line)
        }
    } catch { fail("Unexpected error: \(error) \(message)", file: file, line: line) }
}

func XCTAssertNotEqual<T: Equatable>(_ actual: @autoclosure () throws -> T,
    _ expected: @autoclosure () throws -> T, _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line) {
    do {
        let a = try actual(), b = try expected()
        if a == b { fail("Unexpected equality \(a) \(message)", file: file, line: line) }
    } catch { fail("Unexpected error: \(error) \(message)", file: file, line: line) }
}

func XCTAssertGreaterThan<T: Comparable>(_ actual: @autoclosure () throws -> T,
    _ expected: @autoclosure () throws -> T, _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line) {
    do {
        let a = try actual(), b = try expected()
        if !(a > b) { fail("\(a) is not greater than \(b) \(message)", file: file, line: line) }
    } catch { fail("Unexpected error: \(error) \(message)", file: file, line: line) }
}

func XCTAssertLessThan<T: Comparable>(_ actual: @autoclosure () throws -> T,
    _ expected: @autoclosure () throws -> T, _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line) {
    do {
        let a = try actual(), b = try expected()
        if !(a < b) { fail("\(a) is not less than \(b) \(message)", file: file, line: line) }
    } catch { fail("Unexpected error: \(error) \(message)", file: file, line: line) }
}

func XCTAssertLessThanOrEqual<T: Comparable>(_ actual: @autoclosure () throws -> T,
    _ expected: @autoclosure () throws -> T, _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line) {
    do {
        let a = try actual(), b = try expected()
        if !(a <= b) { fail("\(a) is not less than or equal to \(b) \(message)", file: file, line: line) }
    } catch { fail("Unexpected error: \(error) \(message)", file: file, line: line) }
}

func XCTAssertTrue(_ value: @autoclosure () throws -> Bool, _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line) {
    do { if try !value() { fail("Expected true \(message)", file: file, line: line) } }
    catch { fail("Unexpected error: \(error)", file: file, line: line) }
}

func XCTAssertFalse(_ value: @autoclosure () throws -> Bool, _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line) {
    do { if try value() { fail("Expected false \(message)", file: file, line: line) } }
    catch { fail("Unexpected error: \(error)", file: file, line: line) }
}

func XCTAssertNil(_ value: @autoclosure () throws -> Any?, _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line) {
    do {
        if try value() != nil { fail("Expected nil \(message)", file: file, line: line) }
    } catch { fail("Unexpected error: \(error) \(message)", file: file, line: line) }
}

func XCTAssertThrowsError<T>(_ value: @autoclosure () throws -> T, _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try value(); fail("Expected an error \(message)", file: file, line: line) }
    catch { }
}

func XCTAssertNotNil(_ value: @autoclosure () throws -> Any?, _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line) {
    do { if try value() == nil { fail("Expected a value \(message)", file: file, line: line) } }
    catch { fail("Unexpected error: \(error) \(message)", file: file, line: line) }
}

func XCTUnwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value else {
        fail("Expected a value", file: file, line: line)
        throw UnwrapFailure()
    }
    return value
}

@main
enum HistoryTestRunner {
    @MainActor static func main() {
        let libraryTrashUndoTests = LibraryTrashUndoTests()
        let libraryFocusNativeTests = LibraryFocusNativeTests()
        let libraryKeyboardContractTests = LibraryKeyboardContractTests()
        let libraryKeyboardWorkflowTests = LibraryKeyboardWorkflowTests()
        let libraryStore = LibraryStoreTests()
        let libraryInteraction = LibraryInteractionTests()
        let publicLinks = PublicLinkPolicyTests()
        let requestedUX = RequestedUXTests()
        let imageSearch = ImageSearchTests()
        let shelfSearch = ShelfSearchTests()
        let shelfSearchInteraction = ShelfSearchInteractionTests()
        let shelfSearchMounted = ShelfSearchMountedTests()
        let shelfSearchShortcut = ShelfSearchShortcutTests()
        let shelfSearchNavigation = ShelfSearchNavigationTests()
        let nativeLibrary = LibraryNativeTests()
        let interactions = PreviewInteractionTests()
        let crossShelfPreview = CrossShelfPreviewTests()
        let shelfRemovalNavigation = ShelfRemovalNavigationTests()
        let previewRemoval = PreviewRemovalTests()
        let tests = ImageHistoryTests()
        let settings = SettingsTests()
        let favorites = FavoritesTests()
        let textZoom = TextAndZoomTests()
        let unifiedMarkup = UnifiedMarkupToolbarTests()
        let textDedupStore = TextDedupStoreTests()
        let textDedupLegacy = TextDedupLegacyTests()
        let dual = DualShelfTests()
        let merge = UpstreamMergeTests()
        let imageTextCopyTests = ImageTextCopyTests()
        let directPasteCoordinatorTests = DirectPasteCoordinatorTests()
        let shelfDefaultNavigation = ShelfDefaultNavigationTests()
        let mainWindowPasteFocusTests = MainWindowPasteFocusTests()
        let pasteAccessibility = DirectPasteAccessibilityTests()
        let commandPaletteTests = CommandPaletteTests()
        let actionBarCatalog = ActionBarCatalogTests()
        let actionBarControllers = ActionBarControllerTests()
        let actionBarRouting = ActionBarRoutingTests()
        let keyboardPickerTests = KeyboardPickerTests()
        let shelfPerformance = ShelfPerformanceTests()
        let shelfProjection = ShelfProjectionTests()
        let shelfPresentation = ShelfPresentationTests()
        let textIdentityParity = TextIdentityParityTests()
        let keyboardSpeedTests = KeyboardSpeedTests()
        let shelfPaging = ShelfPagingTests()
        let markupPersistence = ImageMarkupPersistenceTests()
        let markupRenderer = ImageMarkupTests()
        let imageCrop = ImageCropTests()
        let imageCropActions = ImageCropActionTests()
        let imageCropPreview = ImageCropPreviewTests()
        let imageCropCanvas = ImageCropCanvasTests()
        let markupKeyboard = MarkupKeyboardTests()
        let markupInteraction = ImageMarkupInteractionTests()
        let markupRegression = ImageMarkupRegressionTests()
        let namedPinModel = NamedPinModelTests()
        let namedPinPicker = NameAndPinPickerTests()
        let namedPinWorkflow = NameAndPinWorkflowTests()
        let namedShelfLabel = NamedShelfLabelTests()
        let publicUpdates = PublicUpdateChannelTests()
        let cases: [(String, () throws -> Void)] = [
            ("testNativeVisibilityKeepsWindowContentAndHitCoordinatesFixed", shelfPresentation.testNativeVisibilityKeepsWindowContentAndHitCoordinatesFixed),
            ("testRapidVisibilityReversalCannotRunAnEarlierCloseCompletion", shelfPresentation.testRapidVisibilityReversalCannotRunAnEarlierCloseCompletion),
            ("testMixedBatchRestoresOriginalShelfFlagsContentOrganizationAndFiles", libraryTrashUndoTests.testMixedBatchRestoresOriginalShelfFlagsContentOrganizationAndFiles),
            ("testMissingAndAlreadyTrashedItemsDoNotReplaceThePendingUndoBatch", libraryTrashUndoTests.testMissingAndAlreadyTrashedItemsDoNotReplaceThePendingUndoBatch),
            ("testNewestStaleBatchIsSkippedWithoutOverwritingForeignEdits", libraryTrashUndoTests.testNewestStaleBatchIsSkippedWithoutOverwritingForeignEdits),
            ("testSameClockForeignRestoreAndRetrashHasANewGeneration", libraryTrashUndoTests.testSameClockForeignRestoreAndRetrashHasANewGeneration),
            ("testOrdinaryRestoreAndTrashInvalidateOlderOwnUndoEvenAtTheSameClock", libraryTrashUndoTests.testOrdinaryRestoreAndTrashInvalidateOlderOwnUndoEvenAtTheSameClock),
            ("testGenericForeignFlagTransitionsAlsoRotateTheTrashGeneration", libraryTrashUndoTests.testGenericForeignFlagTransitionsAlsoRotateTheTrashGeneration),
            ("testForeignOrganizationAndColumnChangesAreNotOverwritten", libraryTrashUndoTests.testForeignOrganizationAndColumnChangesAreNotOverwritten),
            ("testForeignPermanentRemovalIsSkippedWhileTheRemainingBatchRestores", libraryTrashUndoTests.testForeignPermanentRemovalIsSkippedWhileTheRemainingBatchRestores),
            ("testTrashFailureRollsBackEveryRowAndKeepsThePreviousUndoBatch", libraryTrashUndoTests.testTrashFailureRollsBackEveryRowAndKeepsThePreviousUndoBatch),
            ("testUndoFailureRollsBackTheWholeBatchAndKeepsItRetryable", libraryTrashUndoTests.testUndoFailureRollsBackTheWholeBatchAndKeepsItRetryable),
            ("testTrashAndUndoAcquireTheWriterLockBeforeClockReadsOrRechecks", libraryTrashUndoTests.testTrashAndUndoAcquireTheWriterLockBeforeClockReadsOrRechecks),
            ("testJournalKeepsTheNewestEightyBatchesAndDoesNotSurviveRestart", libraryTrashUndoTests.testJournalKeepsTheNewestEightyBatchesAndDoesNotSurviveRestart),
            ("testTrashGenerationIsAdditiveAndCleanupAndShelfRemovalRotateIt", libraryTrashUndoTests.testTrashGenerationIsAdditiveAndCleanupAndShelfRemovalRotateIt),
            ("testGridSelectionRevealDoesNotStealEditorFocusAndExplicitEntryStillWorks", libraryFocusNativeTests.testGridSelectionRevealDoesNotStealEditorFocusAndExplicitEntryStillWorks),
            ("testListSelectionRevealDoesNotStealEditorFocusAndExplicitEntryStillWorks", libraryFocusNativeTests.testListSelectionRevealDoesNotStealEditorFocusAndExplicitEntryStillWorks),
            ("testNativeContentDoesNotReviveDisabledKeysOrInterceptAnEditorsEquivalents", libraryFocusNativeTests.testNativeContentDoesNotReviveDisabledKeysOrInterceptAnEditorsEquivalents),
            ("testSidebarKeepsNativeTreeExpansionAndCanEnterResultsWithKeyboard", libraryFocusNativeTests.testSidebarKeepsNativeTreeExpansionAndCanEnterResultsWithKeyboard),
            ("testSidebarContextKeyUsesSelectedFolderAndTagMenusWithoutMovingFocus", libraryFocusNativeTests.testSidebarContextKeyUsesSelectedFolderAndTagMenusWithoutMovingFocus),
            ("testInspectorFocusRecognizesSharedFieldEditorAndSkipsEmptySelection", libraryFocusNativeTests.testInspectorFocusRecognizesSharedFieldEditorAndSkipsEmptySelection),
            ("testContentFocusRequestSurvivesAQueryCompletedBeforeTheNativeViewAttaches", libraryFocusNativeTests.testContentFocusRequestSurvivesAQueryCompletedBeforeTheNativeViewAttaches),
            ("testExplicitSearchOrSidebarEntrySupersedesPendingResultFocus", libraryFocusNativeTests.testExplicitSearchOrSidebarEntrySupersedesPendingResultFocus),
            ("testSharedLibraryKeyboardContract", libraryKeyboardContractTests.testSharedLibraryKeyboardContract),
            ("testNativeSearchPendingQueryDownReturnAndEscapeEnterLatestResults", libraryKeyboardWorkflowTests.testNativeSearchPendingQueryDownReturnAndEscapeEnterLatestResults),
            ("testPaneLetterRemapLeavesNativeEditorsAloneButFunctionKeysStillCycle", libraryKeyboardWorkflowTests.testPaneLetterRemapLeavesNativeEditorsAloneButFunctionKeysStillCycle),
            ("testNewNoteAndNewFolderKeysUseNativeInspectorAndSheet", libraryKeyboardWorkflowTests.testNewNoteAndNewFolderKeysUseNativeInspectorAndSheet),
            ("testMarkedSearchCompositionKeepsEscapeInNativeEditorUntilCommitted", libraryKeyboardWorkflowTests.testMarkedSearchCompositionKeepsEscapeInNativeEditorUntilCommitted),
            ("testMixedPreviewKeepsWindowAcrossGridPageAndBoundaryKeys", libraryKeyboardWorkflowTests.testMixedPreviewKeepsWindowAcrossGridPageAndBoundaryKeys),
            ("testPreviewTrashChoosesNeighborAndUndoReusesWindowForRestoredItem", libraryKeyboardWorkflowTests.testPreviewTrashChoosesNeighborAndUndoReusesWindowForRestoredItem),
            ("testFinalPreviewTrashShowsEmptyStateInSameWindowAndBackspaceRestores", libraryKeyboardWorkflowTests.testFinalPreviewTrashShowsEmptyStateInSameWindowAndBackspaceRestores),
            ("testPreviewReturnActivatesFocusedNativeButtonWithoutCopyingSelectedRecord", libraryKeyboardWorkflowTests.testPreviewReturnActivatesFocusedNativeButtonWithoutCopyingSelectedRecord),
            ("testInvalidInspectorDraftBlocksEscapePaneCycleAndNewNoteUntilCorrected", libraryKeyboardWorkflowTests.testInvalidInspectorDraftBlocksEscapePaneCycleAndNewNoteUntilCorrected),
            ("testInvalidPreviewDraftCannotEscapeOrNavigateAwayAndKeepsItsText", libraryKeyboardWorkflowTests.testInvalidPreviewDraftCannotEscapeOrNavigateAwayAndKeepsItsText),
            ("testImageCommandZKeepsMarkupUndoPriorityAndBackspaceUndoesLibraryTrash", libraryKeyboardWorkflowTests.testImageCommandZKeepsMarkupUndoPriorityAndBackspaceUndoesLibraryTrash),
            ("testExplicitSearchOrSidebarEntrySupersedesPendingNewNoteInspectorFocus", libraryFocusNativeTests.testExplicitSearchOrSidebarEntrySupersedesPendingNewNoteInspectorFocus),
            ("testReducedMotionIsImmediateAndPresentationDoesNotClaimKeyboardOwnership", shelfPresentation.testReducedMotionIsImmediateAndPresentationDoesNotClaimKeyboardOwnership),
            ("testSharedTextIdentitiesAgainstLibraryAndLegacyHistory", textIdentityParity.testSharedTextIdentitiesAgainstLibraryAndLegacyHistory),
            ("testRepeatedThreeShelfOpenCloseLeavesInactiveRowsQuietAndRestoresSingleSelection", shelfPerformance.testRepeatedThreeShelfOpenCloseLeavesInactiveRowsQuietAndRestoresSingleSelection),
            ("testClosingActiveSearchClearsItBeforeFreshOpenChoosesImages", shelfPerformance.testClosingActiveSearchClearsItBeforeFreshOpenChoosesImages),
            ("testRepeatedScrollFocusDoesNotInvalidateAllRowsAndExplicitFocusStillWorks", shelfPerformance.testRepeatedScrollFocusDoesNotInvalidateAllRowsAndExplicitFocusStillWorks),
            ("testEveryOverflowingRowAcceptsGapScrollingAcrossAllPresentations", shelfPerformance.testEveryOverflowingRowAcceptsGapScrollingAcrossAllPresentations),
            ("testImageProjectionCacheReflectsPinEditsRemovalAndUndoWithoutLosingOrder", shelfPerformance.testImageProjectionCacheReflectsPinEditsRemovalAndUndoWithoutLosingOrder),
            ("testTextProjectionInvalidatesForEditedPinnedAndRemovedEntries", shelfProjection.testTextProjectionInvalidatesForEditedPinnedAndRemovedEntries),
            ("testLinkProjectionInvalidatesForMetadataOrderPinnedAndRemovedEntries", shelfProjection.testLinkProjectionInvalidatesForMetadataOrderPinnedAndRemovedEntries),
            ("testClampedScrollDoesNotPublishAndStillClampsAfterViewportChange", shelfProjection.testClampedScrollDoesNotPublishAndStillClampsAfterViewportChange),
            ("testRenderStateIgnoresOtherShelfChangesButTracksVisibleInputs", shelfProjection.testRenderStateIgnoresOtherShelfChangesButTracksVisibleInputs),
            ("testMountedRowsOnlyRequestVisibleLinkPayloadChanges", shelfProjection.testMountedRowsOnlyRequestVisibleLinkPayloadChanges),
            ("testOpeningAllShelvesPrefersOnlyFirstImageAndReopeningResets", shelfDefaultNavigation.testOpeningAllShelvesPrefersOnlyFirstImageAndReopeningResets),
            ("testOpeningWithImagesHiddenSelectsFirstNonemptyVisibleShelf", shelfDefaultNavigation.testOpeningWithImagesHiddenSelectsFirstNonemptyVisibleShelf),
            ("testOpeningSkipsEmptyAndFilteredShelvesWithoutInventingSelection", shelfDefaultNavigation.testOpeningSkipsEmptyAndFilteredShelvesWithoutInventingSelection),
            ("testClosedPreviewVerticalArrowsPreserveColumnClampAndClearOtherSelections", shelfDefaultNavigation.testClosedPreviewVerticalArrowsPreserveColumnClampAndClearOtherSelections),
            ("testClosedPreviewVerticalArrowsSkipEmptyAndHiddenShelves", shelfDefaultNavigation.testClosedPreviewVerticalArrowsSkipEmptyAndHiddenShelves),
            ("testClosedPreviewSpaceAndEnterRouteNewActiveShelfWithoutClipboardAccess", shelfDefaultNavigation.testClosedPreviewSpaceAndEnterRouteNewActiveShelfWithoutClipboardAccess),
            ("testSearchEditingKeepsVerticalAndPreviewCopyKeysNative", shelfDefaultNavigation.testSearchEditingKeepsVerticalAndPreviewCopyKeysNative),
            ("testFilteredIncomingScreenshotKeepsFirstTextFallbackSelected", shelfDefaultNavigation.testFilteredIncomingScreenshotKeepsFirstTextFallbackSelected),
            ("testBrowsingPresentationKeepsPreBlurFieldBeforeOwnKeyWindowExists", directPasteCoordinatorTests.testBrowsingPresentationKeepsPreBlurFieldBeforeOwnKeyWindowExists),
            ("testBrowsingPresentationScopeDoesNotRetainStaleFieldOnLaterExternalEntry", directPasteCoordinatorTests.testBrowsingPresentationScopeDoesNotRetainStaleFieldOnLaterExternalEntry),
            ("testBrowsingPresentationStillRejectsFieldChangedAfterCapture", directPasteCoordinatorTests.testBrowsingPresentationStillRejectsFieldChangedAfterCapture),
            ("testNativeMainWindowMouseBoundaryOnlyCapturesOnFreshLeftClick", mainWindowPasteFocusTests.testNativeMainWindowMouseBoundaryOnlyCapturesOnFreshLeftClick),
            ("testMainWindowControllersForwardEarlyCaptureWithoutDisplayingOrChangingKeyDispatch", mainWindowPasteFocusTests.testMainWindowControllersForwardEarlyCaptureWithoutDisplayingOrChangingKeyDispatch),
            ("testMainWindowMouseEntryPreservesOwnHandoffsAndRefreshesLaterExternalField", mainWindowPasteFocusTests.testMainWindowMouseEntryPreservesOwnHandoffsAndRefreshesLaterExternalField),
            ("testOnlyBundledAnonymousChannelIsAccepted", publicUpdates.testOnlyBundledAnonymousChannelIsAccepted),
            ("testMissingOrRelaxedVerificationAndAutomaticInstallationAreRejected", publicUpdates.testMissingOrRelaxedVerificationAndAutomaticInstallationAreRejected),
            ("testOldAutomaticCheckOptOutWinsWithoutChangingSavedPreferences", publicUpdates.testOldAutomaticCheckOptOutWinsWithoutChangingSavedPreferences),
            ("testDirectPasteRestoresMissingInactiveFocusBeforeWritingClipboard", directPasteCoordinatorTests.testDirectPasteRestoresMissingInactiveFocusBeforeWritingClipboard),
            ("testDirectPasteCapturesBlurredEditorAfterReturningFromExistingLibrary", directPasteCoordinatorTests.testDirectPasteCapturesBlurredEditorAfterReturningFromExistingLibrary),
            ("testDirectPasteDeferredFocusStillRejectsSecureOrChangedOriginalField", directPasteCoordinatorTests.testDirectPasteDeferredFocusStillRejectsSecureOrChangedOriginalField),
            ("testDirectPasteWaitsForShortcutReleaseAndStableFocus", directPasteCoordinatorTests.testDirectPasteWaitsForShortcutReleaseAndStableFocus),
            ("testDirectPasteRechecksFieldAndApplicationAfterClipboardWrite", directPasteCoordinatorTests.testDirectPasteRechecksFieldAndApplicationAfterClipboardWrite),
            ("testDirectPasteDismissalCanActivateEditorBeforeItsFocusReturns", directPasteCoordinatorTests.testDirectPasteDismissalCanActivateEditorBeforeItsFocusReturns),
            ("testDirectPasteDoesNotReuseOldFieldOnAnotherVisitToSameApp", directPasteCoordinatorTests.testDirectPasteDoesNotReuseOldFieldOnAnotherVisitToSameApp),
            ("testPasteAccessibilityTextRolesAcceptUnsupportedSetterCapabilityWithoutReadingContent", pasteAccessibility.testPasteAccessibilityTextRolesAcceptUnsupportedSetterCapabilityWithoutReadingContent),
            ("testPasteAccessibilityResolvesContenteditableDescendantsToStableHighestRoot", pasteAccessibility.testPasteAccessibilityResolvesContenteditableDescendantsToStableHighestRoot),
            ("testPasteAccessibilityExplicitEditableHintSupportsCustomEditorRoles", pasteAccessibility.testPasteAccessibilityExplicitEditableHintSupportsCustomEditorRoles),
            ("testPasteAccessibilityDisabledSecureAndReadOnlyDescendantsCannotUseAncestor", pasteAccessibility.testPasteAccessibilityDisabledSecureAndReadOnlyDescendantsCannotUseAncestor),
            ("testPasteAccessibilityBlocksUnsafeAncestorsAndConflictingReadOnlyHints", pasteAccessibility.testPasteAccessibilityBlocksUnsafeAncestorsAndConflictingReadOnlyHints),
            ("testPasteAccessibilityRejectsUnrelatedRolesAndMalformedFocusOrAncestors", pasteAccessibility.testPasteAccessibilityRejectsUnrelatedRolesAndMalformedFocusOrAncestors),
            ("testPasteAccessibilityAcceptsAppVendedRemoteWebContentElement", pasteAccessibility.testPasteAccessibilityAcceptsAppVendedRemoteWebContentElement),
            ("testPasteAccessibilityFollowsOnlyAppVendedFocusProxiesIntoRemoteEditor", pasteAccessibility.testPasteAccessibilityFollowsOnlyAppVendedFocusProxiesIntoRemoteEditor),
            ("testPasteAccessibilityFocusProxiesKeepStableEditableAncestorAndChangedTargetIdentity", pasteAccessibility.testPasteAccessibilityFocusProxiesKeepStableEditableAncestorAndChangedTargetIdentity),
            ("testPasteAccessibilityFocusProxiesPreserveTerminalSecurityAndReadOnlyRejection", pasteAccessibility.testPasteAccessibilityFocusProxiesPreserveTerminalSecurityAndReadOnlyRejection),
            ("testPasteAccessibilityRejectsMalformedAndCyclicFocusProxies", pasteAccessibility.testPasteAccessibilityRejectsMalformedAndCyclicFocusProxies),
            ("testPasteAccessibilityBoundsFocusedProxyTraversal", pasteAccessibility.testPasteAccessibilityBoundsFocusedProxyTraversal),
            ("testPasteAccessibilityStopsAtSelfVendedTextAndEditableTerminals", pasteAccessibility.testPasteAccessibilityStopsAtSelfVendedTextAndEditableTerminals),
            ("testPasteAccessibilityCannotTraverseSecureOrDisabledContainerProxies", pasteAccessibility.testPasteAccessibilityCannotTraverseSecureOrDisabledContainerProxies),
            ("testPasteAccessibilityDoesNotFollowFocusGettersOnNonContainerDescendants", pasteAccessibility.testPasteAccessibilityDoesNotFollowFocusGettersOnNonContainerDescendants),
            ("testCropDocumentDecodesLegacyAndRoundTripsWithoutChangingVersion", imageCrop.testCropDocumentDecodesLegacyAndRoundTripsWithoutChangingVersion),
            ("testCropValidationRejectsNonFiniteEmptyAndOutsideOriginalBounds", imageCrop.testCropValidationRejectsNonFiniteEmptyAndOutsideOriginalBounds),
            ("testCropUsesBottomLeftQuadrantsAndFullResolutionPixels", imageCrop.testCropUsesBottomLeftQuadrantsAndFullResolutionPixels),
            ("testCropRoundsOutwardAndTinySelectionAlwaysProducesAtLeastOnePixel", imageCrop.testCropRoundsOutwardAndTinySelectionAlwaysProducesAtLeastOnePixel),
            ("testCropAfterEXIFOrientationSelectsDisplayedTopLeft", imageCrop.testCropAfterEXIFOrientationSelectsDisplayedTopLeft),
            ("testCropCompositesOriginalCoordinateAnnotationsAndRetainsAlphaWithoutMutatingSource", imageCrop.testCropCompositesOriginalCoordinateAnnotationsAndRetainsAlphaWithoutMutatingSource),
            ("testCropOnlyPersistsReopensRecropsOriginalAndResetsWithoutLosingOrganization", imageCrop.testCropOnlyPersistsReopensRecropsOriginalAndResetsWithoutLosingOrganization),
            ("testCropInvalidatesOCRAndInvalidCropLeavesStoredPixelsUnchanged", imageCrop.testCropInvalidatesOCRAndInvalidCropLeavesStoredPixelsUnchanged),
            ("testCropShortcutIsConfigurableAndOnlyBelongsToImagePreviewAndMarkup", imageCropActions.testCropShortcutIsConfigurableAndOnlyBelongsToImagePreviewAndMarkup),
            ("testCropCatalogRequiresOneAvailableStillImage", imageCropActions.testCropCatalogRequiresOneAvailableStillImage),
            ("testCropCatalogShowsDirectPreviewShortcutWithoutMarkupPrefix", imageCropActions.testCropCatalogShowsDirectPreviewShortcutWithoutMarkupPrefix),
            ("testCropCatalogHasImageEditingMetadataAndBilingualSearchAliases", imageCropActions.testCropCatalogHasImageEditingMetadataAndBilingualSearchAliases),
            ("testCropRemappingRejectsSharedImageToolConflictsAndHonorsLegacyOverrides", imageCropActions.testCropRemappingRejectsSharedImageToolConflictsAndHonorsLegacyOverrides),
            ("testCropShortcutAppliesAndSavesThenReturnsToBrowsingInSameWindow", imageCropPreview.testCropShortcutAppliesAndSavesThenReturnsToBrowsingInSameWindow),
            ("testCropEscapeAndNoOpEnterDoNotSaveOrAlterExistingCrop", imageCropPreview.testCropEscapeAndNoOpEnterDoNotSaveOrAlterExistingCrop),
            ("testCropUndoRedoPreservesAnnotationsAndRefitsEditingCanvas", imageCropPreview.testCropUndoRedoPreservesAnnotationsAndRefitsEditingCanvas),
            ("testLeavingCropFlushesChosenAreaAndFailedSaveRetainsRetryableDocument", imageCropPreview.testLeavingCropFlushesChosenAreaAndFailedSaveRetainsRetryableDocument),
            ("testCropToolbarCanResetAndApplyToRestoreFullOriginal", imageCropPreview.testCropToolbarCanResetAndApplyToRestoreFullOriginal),
            ("testActionBarCropOpensCapturedShelfImageDirectly", imageCropPreview.testActionBarCropOpensCapturedShelfImageDirectly),
            ("testCropDraftAppliesOnceAndUndoRedoKeepOriginalMarks", imageCropCanvas.testCropDraftAppliesOnceAndUndoRedoKeepOriginalMarks),
            ("testApplyingUnchangedFullOrExistingCropSucceedsWithoutPhantomUndo", imageCropCanvas.testApplyingUnchangedFullOrExistingCropSucceedsWithoutPhantomUndo),
            ("testCropMoveAndCornerResizeClampToImageAndMinimumSize", imageCropCanvas.testCropMoveAndCornerResizeClampToImageAndMinimumSize),
            ("testCancelledCropGestureRestoresDraftAndCancelNeverMutatesDocument", imageCropCanvas.testCancelledCropGestureRestoresDraftAndCancelNeverMutatesDocument),
            ("testResetFullSelectionUncropsWithoutClearingAnnotationsAndIsUndoable", imageCropCanvas.testResetFullSelectionUncropsWithoutClearingAnnotationsAndIsUndoable),
            ("testCropSelectionUsesOriginalUnitCoordinatesAtEveryCanvasZoom", imageCropCanvas.testCropSelectionUsesOriginalUnitCoordinatesAtEveryCanvasZoom),
            ("testPostCropDrawingSelectionMovementAndResizeUseOriginalImageCoordinates", imageCropCanvas.testPostCropDrawingSelectionMovementAndResizeUseOriginalImageCoordinates),
            ("testPostCropTextEditorPositionFontAndSavedPointMatchOriginalCoordinates", imageCropCanvas.testPostCropTextEditorPositionFontAndSavedPointMatchOriginalCoordinates),
            ("testSpacePanWhileCroppingDoesNotChangeSelectionOrCommitCrop", imageCropCanvas.testSpacePanWhileCroppingDoesNotChangeSelectionOrCommitCrop),
            ("testApplicationCatalogTeachesScopedShelfShortcutsWithoutEnablingUnavailableActions", actionBarCatalog.testApplicationCatalogTeachesScopedShelfShortcutsWithoutEnablingUnavailableActions),
            ("testActionBarRanksExactTitlesPrefixesAndExplicitAliasesStably", commandPaletteTests.testActionBarRanksExactTitlesPrefixesAndExplicitAliasesStably),
            ("testEffectiveShortcutHintsHonorContextDefaultsExplicitOverridesAndLegacyPrecedence", actionBarCatalog.testEffectiveShortcutHintsHonorContextDefaultsExplicitOverridesAndLegacyPrecedence),
            ("testCatalogOmitsNonNativePreviewKeysAndAllowsNativeSingleShelfSwitching", actionBarCatalog.testCatalogOmitsNonNativePreviewKeysAndAllowsNativeSingleShelfSwitching),
            ("testCatalogToolSequencesFollowEffectiveRemappedBindings", actionBarCatalog.testCatalogToolSequencesFollowEffectiveRemappedBindings),
            ("testShelfButtonOriginWinsOverKeySettingsAndKeepsCapturedPinTarget", actionBarRouting.testShelfButtonOriginWinsOverKeySettingsAndKeepsCapturedPinTarget),
            ("testTakeDownUsesCapturedIDsAndAdvancesFromCapturedFocusAfterSelectionChanges", actionBarRouting.testTakeDownUsesCapturedIDsAndAdvancesFromCapturedFocusAfterSelectionChanges),
            ("testPreviewActionUsesFocusedItemWithinMultiSelection", actionBarRouting.testPreviewActionUsesFocusedItemWithinMultiSelection),
            ("testCopyActionUsesCapturedTextAndRecordsCopyWithoutTouchingGeneralClipboard", actionBarRouting.testCopyActionUsesCapturedTextAndRecordsCopyWithoutTouchingGeneralClipboard),
            ("testActionBarFocusLossDismissesWithoutReclaimingFocusOrExecutingStaleActions", commandPaletteTests.testActionBarFocusLossDismissesWithoutReclaimingFocusOrExecutingStaleActions),
            ("testActionBarFindsExplicitAliasesAndGroupsWithoutExposingInternalIDs", commandPaletteTests.testActionBarFindsExplicitAliasesAndGroupsWithoutExposingInternalIDs),
            ("testActionBarSearchContentsClosesFirstAndRunsOnlyOnce", commandPaletteTests.testActionBarSearchContentsClosesFirstAndRunsOnlyOnce),
            ("testActionBarDisabledReasonsAndActiveStateRemainAccessible", commandPaletteTests.testActionBarDisabledReasonsAndActiveStateRemainAccessible),
            ("testCatalogCoversEveryBrowsingShortcutAndMenuWithoutDuplicateIDs", actionBarCatalog.testCatalogCoversEveryBrowsingShortcutAndMenuWithoutDuplicateIDs),
            ("testCatalogEnablesDirectImageToolsAndTextEditingForCorrectSelectedKind", actionBarCatalog.testCatalogEnablesDirectImageToolsAndTextEditingForCorrectSelectedKind),
            ("testCatalogReflectsRemappedDisabledAndContextSpecificShortcutHints", actionBarCatalog.testCatalogReflectsRemappedDisabledAndContextSpecificShortcutHints),
            ("testCatalogKeepsNativeMarkupShortcutHintsAndAvailabilityInMarkupContext", actionBarCatalog.testCatalogKeepsNativeMarkupShortcutHintsAndAvailabilityInMarkupContext),
            ("testCatalogShelfLibraryTrashAndUpdateAvailabilityDoNotBleedAcrossContexts", actionBarCatalog.testCatalogShelfLibraryTrashAndUpdateAvailabilityDoNotBleedAcrossContexts),
            ("testCopyStaysAvailableForTrashedItemsWhileEditingActionsDoNot", actionBarCatalog.testCopyStaysAvailableForTrashedItemsWhileEditingActionsDoNot),
            ("testCatalogFolderTagCommandsUseStableIDsAndCurrentScope", actionBarCatalog.testCatalogFolderTagCommandsUseStableIDsAndCurrentScope),
            ("testCatalogBilingualKeywordsAreExplicitAndNeverIncludeOpaqueIdentifiers", actionBarCatalog.testCatalogBilingualKeywordsAreExplicitAndNeverIncludeOpaqueIdentifiers),
            ("testCatalogActiveStatesFollowCurrentShelfAndLibraryFilters", actionBarCatalog.testCatalogActiveStatesFollowCurrentShelfAndLibraryFilters),
            ("testShelfCommandsOpenWhileSearchingAndPlainRemappedKeysStillType", actionBarControllers.testShelfCommandsOpenWhileSearchingAndPlainRemappedKeysStillType),
            ("testLibraryExplicitActionsShareSelectionAndLeaveNativeEditingKeysAlone", actionBarControllers.testLibraryExplicitActionsShareSelectionAndLeaveNativeEditingKeysAlone),
            ("testMarkerActionOpensEditingAndMenuCommandsPreserveFailedSaveDraft", actionBarControllers.testMarkerActionOpensEditingAndMenuCommandsPreserveFailedSaveDraft),
            ("testLibraryPreviewActionsKeepCapturedRecordSeparateFromGridSelection", actionBarControllers.testLibraryPreviewActionsKeepCapturedRecordSeparateFromGridSelection),
            ("testDiscoverableCommandsControlsUseCurrentBindingsWithoutChangingRecords", actionBarControllers.testDiscoverableCommandsControlsUseCurrentBindingsWithoutChangingRecords),
            ("testDetailsRevealUsesCapturedRecordAcrossFiltersAndRetainedScopes", actionBarControllers.testDetailsRevealUsesCapturedRecordAcrossFiltersAndRetainedScopes),
            ("testOptionArrowsPageNumberedGroupsPreserveSlotAndOnlyChangeActiveShelf", shelfPaging.testOptionArrowsPageNumberedGroupsPreserveSlotAndOnlyChangeActiveShelf),
            ("testNarrowPagesAndPartialLastPageRemainNumberedWithoutWrapping", shelfPaging.testNarrowPagesAndPartialLastPageRemainNumberedWithoutWrapping),
            ("testWidePagesWorkWithoutScrollAndResizeOrManualScrollRebasesNumbering", shelfPaging.testWidePagesWorkWithoutScrollAndResizeOrManualScrollRebasesNumbering),
            ("testPagesUseOnlySearchAndPinnedResultsOfTheActiveShelf", shelfPaging.testPagesUseOnlySearchAndPinnedResultsOfTheActiveShelf),
            ("testFallingImagesKeepTheirVisualColumnsAndCannotReceivePageFocus", shelfPaging.testFallingImagesKeepTheirVisualColumnsAndCannotReceivePageFocus),
            ("testPagingDefaultsCanBeRemappedAndDoNotTakeOverOlderOverridesOrSearchEditing", shelfPaging.testPagingDefaultsCanBeRemappedAndDoNotTakeOverOlderOverridesOrSearchEditing),
            ("testPreviewPagesKeepOneWindowAndNativeTextWordNavigationWhileEditing", shelfPaging.testPreviewPagesKeepOneWindowAndNativeTextWordNavigationWhileEditing),
            ("testEmptyAndSingleItemRowsDoNotWrapAndCommandArrowBoundariesStillWork", shelfPaging.testEmptyAndSingleItemRowsDoNotWrapAndCommandArrowBoundariesStillWork),
            ("testTextNamePinsWithoutChangingClipboardValueAndSurvivesReopen", namedPinModel.testTextNamePinsWithoutChangingClipboardValueAndSurvivesReopen),
            ("testRenamingAlreadyPinnedNeverUnpinsOrResetsRetentionAndOrganization", namedPinModel.testRenamingAlreadyPinnedNeverUnpinsOrResetsRetentionAndOrganization),
            ("testExternalImageNameCreatesManagedCopyAndAdapterCarriesLabel", namedPinModel.testExternalImageNameCreatesManagedCopyAndAdapterCarriesLabel),
            ("testLinkCustomNamePreservesMetadataAndSearchesBothNamesAndOriginalURL", namedPinModel.testLinkCustomNamePreservesMetadataAndSearchesBothNamesAndOriginalURL),
            ("testTextNameAndBodyBothRemainSearchableThroughShelfQuery", namedPinModel.testTextNameAndBodyBothRemainSearchableThroughShelfQuery),
            ("testInvalidNamesMissingOrDeletedTargetsNeverChangeRowOrRevision", namedPinModel.testInvalidNamesMissingOrDeletedTargetsNeverChangeRowOrRevision),
            ("testUnicodeAndExactNameLimitAreAccepted", namedPinModel.testUnicodeAndExactNameLimitAreAccepted),
            ("testMissingImageCannotPublishNameOrPin", namedPinModel.testMissingImageCannotPublishNameOrPin),
            ("testDatabaseFailureLeavesImageRecordUnchangedAndRecoversUnpublishedCopy", namedPinModel.testDatabaseFailureLeavesImageRecordUnchangedAndRecoversUnpublishedCopy),
            ("testOldHistoryJSONDecodesWithoutNameAndNewNameRoundTrips", namedPinModel.testOldHistoryJSONDecodesWithoutNameAndNewNameRoundTrips),
            ("testLegacyMigrationKeepsOptionalNamesSeparateFromContent", namedPinModel.testLegacyMigrationKeepsOptionalNamesSeparateFromContent),
            ("testNamePickerStartsWithCustomNameOnlyForEveryContentKind", namedPinPicker.testNamePickerStartsWithCustomNameOnlyForEveryContentKind),
            ("testNamePickerEnterPinsCapturedTargetAndLeavesOriginalAndOtherItemsUnchanged", namedPinPicker.testNamePickerEnterPinsCapturedTargetAndLeavesOriginalAndOtherItemsUnchanged),
            ("testNamePickerEscapeCancelsWithoutPinningRetainingOrRenaming", namedPinPicker.testNamePickerEscapeCancelsWithoutPinningRetainingOrRenaming),
            ("testNamePickerValidationLeavesDraftAndTargetIntactUntilCorrection", namedPinPicker.testNamePickerValidationLeavesDraftAndTargetIntactUntilCorrection),
            ("testNamePickerNativeEditingKeysDoNotRunShelfCommands", namedPinPicker.testNamePickerNativeEditingKeysDoNotRunShelfCommands),
            ("testNamePickerFocusSelectsCustomNameAndNativeCompositionDoesNotSave", namedPinPicker.testNamePickerFocusSelectsCustomNameAndNativeCompositionDoesNotSave),
            ("testBatchNamePickerFreezesFirstSeenOrderAndRejectsInvalidSelectionUpfront", namedPinPicker.testBatchNamePickerFreezesFirstSeenOrderAndRejectsInvalidSelectionUpfront),
            ("testBatchNamePickerEnterAdvancesSameWindowAndSelectsEachExistingName", namedPinPicker.testBatchNamePickerEnterAdvancesSameWindowAndSelectsEachExistingName),
            ("testBatchNamePickerEscapeKeepsCompletedNamesAndLeavesRemainderUntouched", namedPinPicker.testBatchNamePickerEscapeKeepsCompletedNamesAndLeavesRemainderUntouched),
            ("testBatchNamePickerInvalidNameAndFailedSaveStayOnCurrentTarget", namedPinPicker.testBatchNamePickerInvalidNameAndFailedSaveStayOnCurrentTarget),
            ("testBatchNamePickerSkipsFutureDeletedItemAndNeverRevivesDeletedCurrentItem", namedPinPicker.testBatchNamePickerSkipsFutureDeletedItemAndNeverRevivesDeletedCurrentItem),
            ("testBatchNamePickerRepeatedAndReentrantEnterCannotDoubleAdvance", namedPinPicker.testBatchNamePickerRepeatedAndReentrantEnterCannotDoubleAdvance),
            ("testBatchNamePickerContextIdentifiesKindsWithoutDisplayingOpaqueTextOrURLSecrets", namedPinPicker.testBatchNamePickerContextIdentifiesKindsWithoutDisplayingOpaqueTextOrURLSecrets),
            ("testBatchNamePickerAdvancingPreservesNativeCompositionOnNextDraft", namedPinPicker.testBatchNamePickerAdvancingPreservesNativeCompositionOnNextDraft),
            ("testBatchNamePickerButtonAndMouseEventSaveWithoutKeyboardOnlyProperties", namedPinPicker.testBatchNamePickerButtonAndMouseEventSaveWithoutKeyboardOnlyProperties),
            ("testNameAndPinShortcutKeepsExistingPinDefaultsAndSupportsRemapping", namedPinWorkflow.testNameAndPinShortcutKeepsExistingPinDefaultsAndSupportsRemapping),
            ("testShelfNamingSnapshotsVisibleBatchAndLeavesSearchTypingAlone", namedPinWorkflow.testShelfNamingSnapshotsVisibleBatchAndLeavesSearchTypingAlone),
            ("testLibraryNamingFlushesDraftAndSnapshotsSelectionWithoutInterceptingNativeEditors", namedPinWorkflow.testLibraryNamingFlushesDraftAndSnapshotsSelectionWithoutInterceptingNativeEditors),
            ("testLibraryNameBatchUsesFilteredSortedVisibleOrderAcrossKinds", namedPinWorkflow.testLibraryNameBatchUsesFilteredSortedVisibleOrderAcrossKinds),
            ("testShelfBatchNamingAdvancesFocusInSamePanelAndEscapeKeepsRemainingUnchanged", namedPinWorkflow.testShelfBatchNamingAdvancesFocusInSamePanelAndEscapeKeepsRemainingUnchanged),
            ("testLibraryBatchNamingKeepsCapturedQueueWhenPinningChangesScope", namedPinWorkflow.testLibraryBatchNamingKeepsCapturedQueueWhenPinningChangesScope),
            ("testShelfPreviewsOpenNamingForDisplayedItemAndPreservePreviewOnCancel", namedPinWorkflow.testShelfPreviewsOpenNamingForDisplayedItemAndPreservePreviewOnCancel),
            ("testTextPreviewOptionPinKeepsEditingKeysAndFlushesBeforeBrowsingNaming", namedPinWorkflow.testTextPreviewOptionPinKeepsEditingKeysAndFlushesBeforeBrowsingNaming),
            ("testLibraryPreviewNamingTargetsDisplayedItemAcrossAllKinds", namedPinWorkflow.testLibraryPreviewNamingTargetsDisplayedItemAcrossAllKinds),
            ("testRenamingPinnedImageRefreshesShelfLabelWithoutChangingImageOrSelection", namedShelfLabel.testRenamingPinnedImageRefreshesShelfLabelWithoutChangingImageOrSelection),
            ("testLongNativeTextNeverSoftWrapsAndCaretScrollsWithinImageEditor", markupRegression.testLongNativeTextNeverSoftWrapsAndCaretScrollsWithinImageEditor),
            ("testExplicitUnicodeNewlinesRemainTwoNativeAndPersistedLines", markupRegression.testExplicitUnicodeNewlinesRemainTwoNativeAndPersistedLines),
            ("testFilledShapeSettingDoesNotMakeStrokeToolsSolidOrStealInteriorClicks", markupRegression.testFilledShapeSettingDoesNotMakeStrokeToolsSolidOrStealInteriorClicks),
            ("testCancelledSelectionMoveRestoresGeometryWithoutPhantomUndo", markupRegression.testCancelledSelectionMoveRestoresGeometryWithoutPhantomUndo),
            ("testCancelledResizeRestoresGeometryAndLoadingDropsPendingGesture", markupRegression.testCancelledResizeRestoresGeometryAndLoadingDropsPendingGesture),
            ("testNativeTextStyleCommitAndZoomPreserveDocumentAndDisposeEditorViewport", markupRegression.testNativeTextStyleCommitAndZoomPreserveDocumentAndDisposeEditorViewport),
            ("testMainLibraryCopyDragAndTrashFlushDirtyPreviewBeforeUsingImage", markupInteraction.testMainLibraryCopyDragAndTrashFlushDirtyPreviewBeforeUsingImage),
            ("testFailedMainLibraryFlushBlocksCopyDragAndTrashWithoutLosingDraft", markupInteraction.testFailedMainLibraryFlushBlocksCopyDragAndTrashWithoutLosingDraft),
            ("testOpeningShelfAfterLibraryFlushesAndClosesOldPreviewForSameItem", markupInteraction.testOpeningShelfAfterLibraryFlushesAndClosesOldPreviewForSameItem),
            ("testMouseDrawingToolsStoreNormalizedGeometryAndConstrainedShapes", markupInteraction.testMouseDrawingToolsStoreNormalizedGeometryAndConstrainedShapes),
            ("testSelectionMoveResizeStyleUndoRedoDeleteAndClear", markupInteraction.testSelectionMoveResizeStyleUndoRedoDeleteAndClear),
            ("testSelectingHollowShapeDoesNotStealInteriorClicksAndMoveClampsToImage", markupInteraction.testSelectingHollowShapeDoesNotStealInteriorClicksAndMoveClampsToImage),
            ("testTextEditingOwnsNativeTypingKeysAndFinishesUnicodeAndExistingText", markupInteraction.testTextEditingOwnsNativeTypingKeysAndFinishesUnicodeAndExistingText),
            ("testMarkupToolShortcutsRemapAndToolbarCallbacksStayInPreview", markupInteraction.testMarkupToolShortcutsRemapAndToolbarCallbacksStayInPreview),
            ("testSpaceHoldPanAndKeyUpKeepMarkupDocumentAndWindowOpen", markupInteraction.testSpaceHoldPanAndKeyUpKeepMarkupDocumentAndWindowOpen),
            ("testCopyFlushesActualStoreMarkupAndPreviewRemainsEditable", markupInteraction.testCopyFlushesActualStoreMarkupAndPreviewRemainsEditable),
            ("testFailedSaveBlocksCopyNavigationAndCloseUntilRetrySucceeds", markupInteraction.testFailedSaveBlocksCopyNavigationAndCloseUntilRetrySucceeds),
            ("testCrossShelfPanelNavigationFlushesAndRestoresSavedMarkup", markupInteraction.testCrossShelfPanelNavigationFlushesAndRestoresSavedMarkup),
            ("testClosingPreviewCommitsPendingNativeTextAndReopeningKeepsEditableVectors", markupInteraction.testClosingPreviewCommitsPendingNativeTextAndReopeningKeepsEditableVectors),
            ("testLibraryPreviewUsesSameMarkupPersistenceCopyAndReopenFlow", markupInteraction.testLibraryPreviewUsesSameMarkupPersistenceCopyAndReopenFlow),
            ("testMarkupPreservesExternalOriginalIdentityAndTemporaryRetention", markupPersistence.testMarkupPreservesExternalOriginalIdentityAndTemporaryRetention),
            ("testReopenAndReeditUseImmutableBaseEvenAfterExternalOriginalIsRemoved", markupPersistence.testReopenAndReeditUseImmutableBaseEvenAfterExternalOriginalIsRemoved),
            ("testMarkupPreservesPinFoldersTagsNotesAndShelfAdapterIdentity", markupPersistence.testMarkupPreservesPinFoldersTagsNotesAndShelfAdapterIdentity),
            ("testCopyExportAndDragUseFlattenedPNGAndCorrectExtension", markupPersistence.testCopyExportAndDragUseFlattenedPNGAndCorrectExtension),
            ("testClearingAllMarksRestoresBaseAndKeepsOriginalRecoverable", markupPersistence.testClearingAllMarksRestoresBaseAndKeepsOriginalRecoverable),
            ("testFailedDocumentRenderAndDatabaseWriteLeavePreviousRecordAndPixelsUntouched", markupPersistence.testFailedDocumentRenderAndDatabaseWriteLeavePreviousRecordAndPixelsUntouched),
            ("testRetiredRenderCleanupRetriesAfterTrashFailureAndNeverTrashesBase", markupPersistence.testRetiredRenderCleanupRetriesAfterTrashFailureAndNeverTrashesBase),
            ("testFailedReeditKeepsExistingVectorsRenderBaseAndCopyPayload", markupPersistence.testFailedReeditKeepsExistingVectorsRenderBaseAndCopyPayload),
            ("testInterruptedAssetJournalRecoveryProtectsCurrentAndBaseReferences", markupPersistence.testInterruptedAssetJournalRecoveryProtectsCurrentAndBaseReferences),
            ("testMarkupInvalidatesOCRPixelsAndLegacyPayloadsStillDecode", markupPersistence.testMarkupInvalidatesOCRPixelsAndLegacyPayloadsStillDecode),
            ("testDocumentRoundTripPreservesAllVectorToolsAndStyles", markupRenderer.testDocumentRoundTripPreservesAllVectorToolsAndStyles),
            ("testValidationRejectsNonFiniteOutOfRangeAndMalformedElements", markupRenderer.testValidationRejectsNonFiniteOutOfRangeAndMalformedElements),
            ("testDecodeAndRendererRejectInvalidStoredDocuments", markupRenderer.testDecodeAndRendererRejectInvalidStoredDocuments),
            ("testDocumentBoundsPreventHugePathsAndText", markupRenderer.testDocumentBoundsPreventHugePathsAndText),
            ("testRenderRetainsFullResolutionAndNeverMutatesSource", markupRenderer.testRenderRetainsFullResolutionAndNeverMutatesSource),
            ("testEmptyDocumentRetainsTransparencyAndPixels", markupRenderer.testEmptyDocumentRetainsTransparencyAndPixels),
            ("testMarkerIsTranslucentWhilePenIsOpaque", markupRenderer.testMarkerIsTranslucentWhilePenIsOpaque),
            ("testNormalizedStrokeAndPositionScaleWithImageResolution", markupRenderer.testNormalizedStrokeAndPositionScaleWithImageResolution),
            ("testEllipseAndRectangleFillRespectHollowCentersAndLayerOrder", markupRenderer.testEllipseAndRectangleFillRespectHollowCentersAndLayerOrder),
            ("testArrowIncludesVisibleHeadAndSinglePointPenMakesDot", markupRenderer.testArrowIncludesVisibleHeadAndSinglePointPenMakesDot),
            ("testUnicodeTextRendersAtImageCoordinates", markupRenderer.testUnicodeTextRendersAtImageCoordinates),
            ("testEXIFRotationUsesDisplayedOrientationWithoutDownsampling", markupRenderer.testEXIFRotationUsesDisplayedOrientationWithoutDownsampling),
            ("testSourceErrorsAndSelectionBoundsArePredictable", markupRenderer.testSourceErrorsAndSelectionBoundsArePredictable),
            ("testMalformedOversizedPNGIsRejected", markupRenderer.testMalformedOversizedPNGIsRejected),
            ("testMarkupToggleIsImageOnlyAndToolsHaveSeparateContext", markupKeyboard.testMarkupToggleIsImageOnlyAndToolsHaveSeparateContext),
            ("testMarkupShortcutsPersistAndDisableWithoutChangingBrowsingKeys", markupKeyboard.testMarkupShortcutsPersistAndDisableWithoutChangingBrowsingKeys),
            ("testMarkupToolConflictsAreRejectedIncludingToggleAndTransferKeys", markupKeyboard.testMarkupToolConflictsAreRejectedIncludingToggleAndTransferKeys),
            ("testToolbarSelectionRefreshIsSilentAndUserActionsUseCallbacks", markupKeyboard.testToolbarSelectionRefreshIsSilentAndUserActionsUseCallbacks),
            ("testFreshCachedOCRCopiesWithoutRecognitionAndPreservesRecord", imageTextCopyTests.testFreshCachedOCRCopiesWithoutRecognitionAndPreservesRecord),
            ("testStaleFingerprintAndMismatchedIndexPathRequireFreshRecognition", imageTextCopyTests.testStaleFingerprintAndMismatchedIndexPathRequireFreshRecognition),
            ("testEmptyFailedAndUnavailableOCRLeaveExistingClipboardUntouched", imageTextCopyTests.testEmptyFailedAndUnavailableOCRLeaveExistingClipboardUntouched),
            ("testImageDeletedOrEditedDuringRecognitionCannotCopyStaleText", imageTextCopyTests.testImageDeletedOrEditedDuringRecognitionCannotCopyStaleText),
            ("testCancelledAndSupersededRecognitionNeverOverwriteNewerCopy", imageTextCopyTests.testCancelledAndSupersededRecognitionNeverOverwriteNewerCopy),
            ("testDirectPasteKeepsOriginalFieldAcrossOwnViewsAndSendsOnlyToCapturedProcess", directPasteCoordinatorTests.testDirectPasteKeepsOriginalFieldAcrossOwnViewsAndSendsOnlyToCapturedProcess),
            ("testOwnActivationCapturesLatestFieldWhenReturningToAlreadyOpenWindow", directPasteCoordinatorTests.testOwnActivationCapturesLatestFieldWhenReturningToAlreadyOpenWindow),
            ("testOwnActivationPreservesCapturedFieldThroughNoneditableBlurContainer", directPasteCoordinatorTests.testOwnActivationPreservesCapturedFieldThroughNoneditableBlurContainer),
            ("testDirectPasteWaitsForNonactivatingSourceToReleaseKeyFocus", directPasteCoordinatorTests.testDirectPasteWaitsForNonactivatingSourceToReleaseKeyFocus),
            ("testAppCapturePolicyRefreshesExternalReentryAndPreservesOwnPanelHandoffs", directPasteCoordinatorTests.testAppCapturePolicyRefreshesExternalReentryAndPreservesOwnPanelHandoffs),
            ("testNewOwnBrowsingActionCancelsPendingPasteWithoutSendingOrCopying", directPasteCoordinatorTests.testNewOwnBrowsingActionCancelsPendingPasteWithoutSendingOrCopying),
            ("testPreviewMouseReentryCapturesLatestExternalFieldBeforeTakingFocus", directPasteCoordinatorTests.testPreviewMouseReentryCapturesLatestExternalFieldBeforeTakingFocus),
            ("testPreviewMouseFocusPreservesOwnHandoffsAndIgnoresNonEntryEvents", directPasteCoordinatorTests.testPreviewMouseFocusPreservesOwnHandoffsAndIgnoresNonEntryEvents),
            ("testShelfMouseReentryRefreshesTargetBeforeLibraryActionTakesFocus", directPasteCoordinatorTests.testShelfMouseReentryRefreshesTargetBeforeLibraryActionTakesFocus),
            ("testPasteDismissalBlocksPointerReopenUntilMenuBarExit", directPasteCoordinatorTests.testPasteDismissalBlocksPointerReopenUntilMenuBarExit),
            ("testShelfMouseCapturePreservesOwnHandoffsAndIgnoresNonEntryEvents", directPasteCoordinatorTests.testShelfMouseCapturePreservesOwnHandoffsAndIgnoresNonEntryEvents),
            ("testLatestExternalActivationRejectsInvalidTargetInsteadOfReusingOlderApp", directPasteCoordinatorTests.testLatestExternalActivationRejectsInvalidTargetInsteadOfReusingOlderApp),
            ("testDirectPasteMissingPermissionTargetAndSecureFieldsNeverChangeClipboardOrSend", directPasteCoordinatorTests.testDirectPasteMissingPermissionTargetAndSecureFieldsNeverChangeClipboardOrSend),
            ("testDirectPasteChangedFieldAppAndTerminatedTargetAbortBeforeClipboardWrite", directPasteCoordinatorTests.testDirectPasteChangedFieldAppAndTerminatedTargetAbortBeforeClipboardWrite),
            ("testDirectPasteWaitsForActivationAndRevalidatesFieldBeforeSending", directPasteCoordinatorTests.testDirectPasteWaitsForActivationAndRevalidatesFieldBeforeSending),
            ("testDirectPasteCopyFailureTimeoutAndSenderFailureDoNotReportSuccess", directPasteCoordinatorTests.testDirectPasteCopyFailureTimeoutAndSenderFailureDoNotReportSuccess),
            ("testDirectPasteCancellationDuringDismissalPreventsActivationAndEvents", directPasteCoordinatorTests.testDirectPasteCancellationDuringDismissalPreventsActivationAndEvents),
            ("testCommandPaletteFiltersTitleAndSubtitleTokensWithoutExposingInternalIDs", commandPaletteTests.testCommandPaletteFiltersTitleAndSubtitleTokensWithoutExposingInternalIDs),
            ("testCommandPaletteArrowsSkipDisabledCommandsClampAndPreserveTextEditingShortcuts", commandPaletteTests.testCommandPaletteArrowsSkipDisabledCommandsClampAndPreserveTextEditingShortcuts),
            ("testCommandPaletteNativeEditorSearchesAndClosesBeforeRunningAction", commandPaletteTests.testCommandPaletteNativeEditorSearchesAndClosesBeforeRunningAction),
            ("testCommandPaletteEscapeCancelsAndDisabledCommandsCannotExecute", commandPaletteTests.testCommandPaletteEscapeCancelsAndDisabledCommandsCannotExecute),
            ("testFolderSearchMatchesFoldedParentPathsAndNeverPinsHiddenChoice", keyboardPickerTests.testFolderSearchMatchesFoldedParentPathsAndNeverPinsHiddenChoice),
            ("testFolderRecentsAreIsolatedPersistentBoundedAndRecordedOnlyAfterSuccess", keyboardPickerTests.testFolderRecentsAreIsolatedPersistentBoundedAndRecordedOnlyAfterSuccess),
            ("testFolderKeyboardCreationCanCancelAndKeepsNativeEditingKeys", keyboardPickerTests.testFolderKeyboardCreationCanCancelAndKeepsNativeEditingKeys),
            ("testTagSearchAddsExistingTagToMixedSnapshotWithoutChangingFavorites", keyboardPickerTests.testTagSearchAddsExistingTagToMixedSnapshotWithoutChangingFavorites),
            ("testTagCreationCancellationAndFailureDoNotPartiallyMutateBatch", keyboardPickerTests.testTagCreationCancellationAndFailureDoNotPartiallyMutateBatch),
            ("testPickerNativeFieldCommandsMoveResultsButLeaveTextEditingShortcutsAlone", keyboardPickerTests.testPickerNativeFieldCommandsMoveResultsButLeaveTextEditingShortcutsAlone),
            ("testPasteAndBrowserOpenDefaultsAreUnambiguousAndLegacyOverrideRemainsIntentional", keyboardSpeedTests.testPasteAndBrowserOpenDefaultsAreUnambiguousAndLegacyOverrideRemainsIntentional),
            ("testTextEditorCommandReturnFinishesBeforeBrowseCommandReturnCanPaste", keyboardSpeedTests.testTextEditorCommandReturnFinishesBeforeBrowseCommandReturnCanPaste),
            ("testEditedPreviewOutsideSharedSearchResultsStillCopiesAndPastesDisplayedRecord", keyboardSpeedTests.testEditedPreviewOutsideSharedSearchResultsStillCopiesAndPastesDisplayedRecord),
            ("testQuickNumbersUseVisibleFilteredViewportInEveryShelfAndNeverCaptureSearchTyping", keyboardSpeedTests.testQuickNumbersUseVisibleFilteredViewportInEveryShelfAndNeverCaptureSearchTyping),
            ("testQuickNumbersDoNotCompressImageColumnsWhileAnItemIsFalling", keyboardSpeedTests.testQuickNumbersDoNotCompressImageColumnsWhileAnItemIsFalling),
            ("testSpeedActionsAndQuickSelectionRemapAndUseOnlyTheActiveRow", keyboardSpeedTests.testSpeedActionsAndQuickSelectionRemapAndUseOnlyTheActiveRow),
            ("testGlobalSearchShortcutDefaultDisableAndCustomPersistenceRejectInvalidValues", keyboardSpeedTests.testGlobalSearchShortcutDefaultDisableAndCustomPersistenceRejectInvalidValues),
            ("testUnreadableImageAfterRemovalOrUndoKeepsUndoablePanelWithoutStaleActions", previewRemoval.testUnreadableImageAfterRemovalOrUndoKeepsUndoablePanelWithoutStaleActions),
            ("testSessionRemovalActsOnCurrentItemOnlyAndSelectsNextThenPrevious", previewRemoval.testSessionRemovalActsOnCurrentItemOnlyAndSelectsNextThenPrevious),
            ("testPreviewRemoveAndUndoReuseVisiblePanelForEveryKind", previewRemoval.testPreviewRemoveAndUndoReuseVisiblePanelForEveryKind),
            ("testLastItemRemovalKeepsUndoableEmptyPanelWithoutStaleActions", previewRemoval.testLastItemRemovalKeepsUndoableEmptyPanelWithoutStaleActions),
            ("testFilteredPinnedPreviewRemovalAndUndoStayInsideVisibleResults", previewRemoval.testFilteredPinnedPreviewRemovalAndUndoStayInsideVisibleResults),
            ("testFailedRemovalAndUndoPreserveCurrentRendererAndCanRetry", previewRemoval.testFailedRemovalAndUndoPreserveCurrentRendererAndCanRetry),
            ("testTextEditingRetainsNativeRemoveKeysAndRestoresSavedDraft", previewRemoval.testTextEditingRetainsNativeRemoveKeysAndRestoresSavedDraft),
            ("testUndoAfterCrossShelfNavigationRestoresMostRecentRemovalKindInSamePanel", previewRemoval.testUndoAfterCrossShelfNavigationRestoresMostRecentRemovalKindInSamePanel),
            ("testRepeatedShelfRemovalSelectsNextThenPreviousAndFinallyClearsEveryKind", shelfRemovalNavigation.testRepeatedShelfRemovalSelectsNextThenPreviousAndFinallyClearsEveryKind),
            ("testBatchRemovalAnchorsAtFocusedVisibleItemAndFallsBackToEarliestSelection", shelfRemovalNavigation.testBatchRemovalAnchorsAtFocusedVisibleItemAndFallsBackToEarliestSelection),
            ("testSearchAndPinnedRemovalAndBoundaryNavigationUseOnlyDisplayedResults", shelfRemovalNavigation.testSearchAndPinnedRemovalAndBoundaryNavigationUseOnlyDisplayedResults),
            ("testFailedShelfRemovalPreservesSelectionAndRetrySelectsNeighbor", shelfRemovalNavigation.testFailedShelfRemovalPreservesSelectionAndRetrySelectsNeighbor),
            ("testCommandArrowBoundariesRespectActiveShelfRemappingAndNativeSearchEditing", shelfRemovalNavigation.testCommandArrowBoundariesRespectActiveShelfRemappingAndNativeSearchEditing),
            ("testPreviewCommandBoundariesKeepPanelAndRespectTextEditing", shelfRemovalNavigation.testPreviewCommandBoundariesKeepPanelAndRespectTextEditing),
            ("testPreviewShelfNavigationPreservesFilteredColumnAndClearsOtherSelections", crossShelfPreview.testPreviewShelfNavigationPreservesFilteredColumnAndClearsOtherSelections),
            ("testPreviewShelfNavigationSkipsHiddenEmptyAndRecordingOnlyRows", crossShelfPreview.testPreviewShelfNavigationSkipsHiddenEmptyAndRecordingOnlyRows),
            ("testAppPreviewChangesKindsInSameVisiblePanelAndRoutesCurrentCopyAndPin", crossShelfPreview.testAppPreviewChangesKindsInSameVisiblePanelAndRoutesCurrentCopyAndPin),
            ("testPreviewReturnCopiesDisplayedItemAndClosesWhileCommandCopyAndToolbarStayOpen", crossShelfPreview.testPreviewReturnCopiesDisplayedItemAndClosesWhileCommandCopyAndToolbarStayOpen),
            ("testPreviewReturnKeepsFailedCopiesAndEditableDraftsOpen", crossShelfPreview.testPreviewReturnKeepsFailedCopiesAndEditableDraftsOpen),
            ("testTextDraftStaysInEditorUntilSavedBeforeCrossShelfNavigation", crossShelfPreview.testTextDraftStaysInEditorUntilSavedBeforeCrossShelfNavigation),
            ("testUnreadableDestinationImageKeepsCurrentPreviewAndSelectionVisible", crossShelfPreview.testUnreadableDestinationImageKeepsCurrentPreviewAndSelectionVisible),
            ("testSearchArrowsChangeShelvesPreserveFilteredColumnAndClamp", shelfSearchNavigation.testSearchArrowsChangeShelvesPreserveFilteredColumnAndClamp),
            ("testVerticalSearchSkipsEmptyRowsAndNeverReopensHiddenRows", shelfSearchNavigation.testVerticalSearchSkipsEmptyRowsAndNeverReopensHiddenRows),
            ("testSpacePreviewsAndReturnCopiesOnlyFocusedFilteredResultsAcrossKinds", shelfSearchNavigation.testSpacePreviewsAndReturnCopiesOnlyFocusedFilteredResultsAcrossKinds),
            ("testRemappedVerticalActionsRespectNativeEditingAndKeepOldBehaviorOutsideSearch", shelfSearchNavigation.testRemappedVerticalActionsRespectNativeEditingAndKeepOldBehaviorOutsideSearch),
            ("testSwiftUIMountedImageSearchKeepsNativeEditorAndFiltersTypedOCR", shelfSearchMounted.testSwiftUIMountedImageSearchKeepsNativeEditorAndFiltersTypedOCR),
            ("testFloatingSearchPanelCentersAndReceivesClicksAtNarrowAndWideWidths", shelfSearchMounted.testFloatingSearchPanelCentersAndReceivesClicksAtNarrowAndWideWidths),
            ("testImageResultClickLeavesNativeEditorAndKeepsSearchFilter", shelfSearchInteraction.testImageResultClickLeavesNativeEditorAndKeepsSearchFilter),
            ("testSharedSearchFiltersAllVisibleShelvesAndNavigationCopyPinAndCloseUseFilteredItems", shelfSearchInteraction.testSharedSearchFiltersAllVisibleShelvesAndNavigationCopyPinAndCloseUseFilteredItems),
            ("testSharedQueryFollowsVisibleTogglesPinsAndClosingClearsPendingFilters", shelfSearchInteraction.testSharedQueryFollowsVisibleTogglesPinsAndClosingClearsPendingFilters),
            ("testNativeSearchEditorKeepsTypingKeysAndReturnsFocusForBrowsing", shelfSearchInteraction.testNativeSearchEditorKeepsTypingKeysAndReturnsFocusForBrowsing),
            ("testShelfSearchDefaultKeepsTakeDownAndLibrarySearchIndependent", shelfSearchShortcut.testShelfSearchDefaultKeepsTakeDownAndLibrarySearchIndependent),
            ("testShelfSearchRemappingPersistsAndCanBeDisabledAndReset", shelfSearchShortcut.testShelfSearchRemappingPersistsAndCanBeDisabledAndReset),
            ("testShelfSearchRespectsExistingCustomBindingsAndContextConflicts", shelfSearchShortcut.testShelfSearchRespectsExistingCustomBindingsAndContextConflicts),
            ("testShelfSearchScopesTemporaryAndSavedMatchesToCurrentKindMembershipAndPins", shelfSearch.testShelfSearchScopesTemporaryAndSavedMatchesToCurrentKindMembershipAndPins),
            ("testShelfSearchUsesTitlesTextNotesURLsTagsAndCurrentImageOCRWithLiteralUnicodeTerms", shelfSearch.testShelfSearchUsesTitlesTextNotesURLsTagsAndCurrentImageOCRWithLiteralUnicodeTerms),
            ("testShelfSearchModelDebouncesLatestQueryKeepsKindsIndependentAndDropsClosedResults", shelfSearch.testShelfSearchModelDebouncesLatestQueryKeepsKindsIndependentAndDropsClosedResults),
            ("testShelfSearchRefreshesOpenQueriesAfterEditsPinsMembershipAndOCRIndexChanges", shelfSearch.testShelfSearchRefreshesOpenQueriesAfterEditsPinsMembershipAndOCRIndexChanges),
            ("testClosedLibraryDefersCaptureQueriesAndRefreshesOnceOnReopen", nativeLibrary.testClosedLibraryDefersCaptureQueriesAndRefreshesOnceOnReopen),
            ("testClosingDuringSearchDebounceRestoresQueryAndFailedDraftBlocksSuspension", nativeLibrary.testClosingDuringSearchDebounceRestoresQueryAndFailedDraftBlocksSuspension),
            ("testOpenLinkPreviewReceivesMetadataAndPinWithoutRepublishingIDs", nativeLibrary.testOpenLinkPreviewReceivesMetadataAndPinWithoutRepublishingIDs),
            ("testNativeToolbarAndSplitColumnsPreserveRecordsAndInspectorPreference", nativeLibrary.testNativeToolbarAndSplitColumnsPreserveRecordsAndInspectorPreference),
            ("testSidebarArrowKeysAndNestedScopeUseNativeSelectionAndRevealAncestors", nativeLibrary.testSidebarArrowKeysAndNestedScopeUseNativeSelectionAndRevealAncestors),
            ("testNativeListSortSelectionAndCombinedDragPayloadKeepRecordIdentities", nativeLibrary.testNativeListSortSelectionAndCombinedDragPayloadKeepRecordIdentities),
            ("testInspectorRelationshipsRefreshAfterRenameAndRemovalAndRemainDuringDrafts", nativeLibrary.testInspectorRelationshipsRefreshAfterRenameAndRemovalAndRemainDuringDrafts),
            ("testTenThousandRecordsDoNotRebuildUnchangedVisibleCards", nativeLibrary.testTenThousandRecordsDoNotRebuildUnchangedVisibleCards),
            ("testLanguagePreferencePersistsRejectsInvalidAndRestoresSystemWithoutChangingOtherPreferences", imageSearch.testLanguagePreferencePersistsRejectsInvalidAndRestoresSystemWithoutChangingOtherPreferences),
            ("testStatusCountsOnlyEnabledShelvesAndKeepsExactTotalsWithCappedBadge", imageSearch.testStatusCountsOnlyEnabledShelvesAndKeepsExactTotalsWithCappedBadge),
            ("testOCRIndexIsPersistentCachedAndPreservesPayloadThenReindexesEditedPixels", imageSearch.testOCRIndexIsPersistentCachedAndPreservesPayloadThenReindexesEditedPixels),
            ("testVisualSuggestionsHonorScopeKindPinTagAndTrashAndTextMatchesRankFirst", imageSearch.testVisualSuggestionsHonorScopeKindPinTagAndTrashAndTextMatchesRankFirst),
            ("testMalformedOrUnrelatedVisualVectorsDoNotCreateMatches", imageSearch.testMalformedOrUnrelatedVisualVectorsDoNotCreateMatches),
            ("testMobileCLIPFindsImageContentWithoutOCRAndTokenizerMatchesReference", imageSearch.testMobileCLIPFindsImageContentWithoutOCRAndTokenizerMatchesReference),
            ("testSingleKeysOpenLibraryPinFilterAndPersistRemappingAcrossContexts", requestedUX.testSingleKeysOpenLibraryPinFilterAndPersistRemappingAcrossContexts),
            ("testClosingClearsEverySelectionAndReopeningSelectsFirstVisibleItemsAndPage", requestedUX.testClosingClearsEverySelectionAndReopeningSelectsFirstVisibleItemsAndPage),
            ("testSingleShelfOpeningLeavesHiddenRowsEmptyAndRepeatedRevealPreservesBatch", requestedUX.testSingleShelfOpeningLeavesHiddenRowsEmptyAndRepeatedRevealPreservesBatch),
            ("testOpeningSelectsFirstPinnedItemAndLeavesEmptyFilteredShelvesUnselected", requestedUX.testOpeningSelectsFirstPinnedItemAndLeavesEmptyFilteredShelvesUnselected),
            ("testEnablingShelfSelectsItsFirstItemWithoutResettingAlreadyVisibleRows", requestedUX.testEnablingShelfSelectsItsFirstItemWithoutResettingAlreadyVisibleRows),
            ("testSRemovesOnlySelectedShelfItemsAndKeepsSavedRecordsRecoverable", requestedUX.testSRemovesOnlySelectedShelfItemsAndKeepsSavedRecordsRecoverable),
            ("testBackspaceUndoesWholeShelfRemovalBatchesWithoutLosingLaterEdits", requestedUX.testBackspaceUndoesWholeShelfRemovalBatchesWithoutLosingLaterEdits),
            ("testShiftShelfTogglesPersistLayoutAndLastShelfClosesLine", requestedUX.testShiftShelfTogglesPersistLayoutAndLastShelfClosesLine),
            ("testFolderPickerCancelsAndPinsMixedSnapshotAtomicallyWithArrowAndEnter", requestedUX.testFolderPickerCancelsAndPinsMixedSnapshotAtomicallyWithArrowAndEnter),
            ("testYouTubeBlackPaddingIsRemovedWhileRealFourThreeAndOtherLinksStayIntact", requestedUX.testYouTubeBlackPaddingIsRemovedWhileRealFourThreeAndOtherLinksStayIntact),
            ("testShortcutRecorderCapturesPlainAndCommandKeysAndSavesChosenValue", requestedUX.testShortcutRecorderCapturesPlainAndCommandKeysAndSavesChosenValue),
            ("testShortcutConflictsAndResetAreRejectedWithoutChangingExistingBindings", requestedUX.testShortcutConflictsAndResetAreRejectedWithoutChangingExistingBindings),
            ("testIndependentRetentionKeepsOtherKindsAndPermanentItemsAndSurvivesReopen", requestedUX.testIndependentRetentionKeepsOtherKindsAndPermanentItemsAndSurvivesReopen),
            ("testFinishingTextEditSavesBeforeBrowsingAndFailedSaveKeepsEditableDraft", requestedUX.testFinishingTextEditSavesBeforeBrowsingAndFailedSaveKeepsEditableDraft),
            ("testLinkPreviewFitsThumbnailAndOpensExactCurrentURLWithConfiguredKey", requestedUX.testLinkPreviewFitsThumbnailAndOpensExactCurrentURLWithConfiguredKey),
            ("testEditingSearchResultKeepsDraftUntilDoneAndArrowsUseRemainingResults", requestedUX.testEditingSearchResultKeepsDraftUntilDoneAndArrowsUseRemainingResults),
            ("testNativeSearchEscapeRoutesImmediateSelectAllToCollectionAndLeavesOtherEditorsAlone", libraryInteraction.testNativeSearchEscapeRoutesImmediateSelectAllToCollectionAndLeavesOtherEditorsAlone),
            ("testPagedTagSummariesRefreshAfterRenameAndRemovalWithoutChangingSelection", libraryInteraction.testPagedTagSummariesRefreshAfterRenameAndRemovalWithoutChangingSelection),
            ("testTextCopiedWithWindowsLineEndingsIsTitledByItsFirstLine", libraryInteraction.testTextCopiedWithWindowsLineEndingsIsTitledByItsFirstLine),
            ("testMigrationPreservesTextBytesDatesFavoritesIDsAndOriginals", libraryStore.testMigrationPreservesTextBytesDatesFavoritesIDsAndOriginals),
            ("testCorruptSourceBlocksMigrationAndDoesNotOverwriteArchive", libraryStore.testCorruptSourceBlocksMigrationAndDoesNotOverwriteArchive),
            ("testFolderTagOrFavoriteRetainsAcrossUnassignUnpinAndExpiry", libraryStore.testFolderTagOrFavoriteRetainsAcrossUnassignUnpinAndExpiry),
            ("testCollectionsAreManyToManyNestedAndRemovalDoesNotDeleteContent", libraryStore.testCollectionsAreManyToManyNestedAndRemovalDoesNotDeleteContent),
            ("testPinnedImageWhoseManagedCopyIsGoneCanStillLeaveTheShelfGoToTrashAndRestore", libraryStore.testPinnedImageWhoseManagedCopyIsGoneCanStillLeaveTheShelfGoToTrashAndRestore),
            ("testMovingFromParentRemovesChildMembershipButKeepsOtherFoldersAndOriginal", libraryStore.testMovingFromParentRemovesChildMembershipButKeepsOtherFoldersAndOriginal),
            ("testDomainFilterIncludesSubdomainsWithLiteralHostBoundaries", libraryStore.testDomainFilterIncludesSubdomainsWithLiteralHostBoundaries),
            ("testBlankOrPaddedItemNameIsIgnoredOrTrimmedLikeWindows", libraryStore.testBlankOrPaddedItemNameIsIgnoredOrTrimmedLikeWindows),
            ("testTagRenameSearchTurkishAndLiteralSQLCharacters", libraryStore.testTagRenameSearchTurkishAndLiteralSQLCharacters),
            ("testTrashRestoresContentAndRelationshipsWithoutMovingOriginal", libraryStore.testTrashRestoresContentAndRelationshipsWithoutMovingOriginal),
            ("testAdaptersShareStableIdentityTextEditsFavoritesAndRestart", libraryStore.testAdaptersShareStableIdentityTextEditsFavoritesAndRestart),
            ("testInvalidBatchRollsBackInsteadOfPartiallyAssigningOrRetaining", libraryStore.testInvalidBatchRollsBackInsteadOfPartiallyAssigningOrRetaining),
            ("testSnapshotIncludesWALCommittedChangesAndIsPrivate", libraryStore.testSnapshotIncludesWALCommittedChangesAndIsPrivate),
            ("testLinkIdentityPreservesMeaningfulParametersAndDeduplicatesVideoForms", libraryStore.testLinkIdentityPreservesMeaningfulParametersAndDeduplicatesVideoForms),
            ("testPagingAndBackgroundQueriesRespectScopeAndResultOrder", libraryStore.testPagingAndBackgroundQueriesRespectScopeAndResultOrder),
            ("testRecapturedLinkMovesLeftAndRenewsTemporaryCaptureWithoutResettingOriginalDate", libraryStore.testRecapturedLinkMovesLeftAndRenewsTemporaryCaptureWithoutResettingOriginalDate),
            ("testRestoringOldCopyAfterRecapturePreservesBothRecordsAndPinsExactImageID", libraryStore.testRestoringOldCopyAfterRecapturePreservesBothRecordsAndPinsExactImageID),
            ("testRouterMakesOneDecisionAndPreservesParagraphsAndIndependentSources", libraryInteraction.testRouterMakesOneDecisionAndPreservesParagraphsAndIndependentSources),
            ("testRouterSkipsPrivateMarkersFilesImagesOwnCopyAndRacesBeforeRecording", libraryInteraction.testRouterSkipsPrivateMarkersFilesImagesOwnCopyAndRacesBeforeRecording),
            ("testTextCaptureDoesNotRevealSwitchShelvesOrRequestFocusInAnyPresentation", libraryInteraction.testTextCaptureDoesNotRevealSwitchShelvesOrRequestFocusInAnyPresentation),
            ("testThreeShelvesPersistCycleAndUseIndependentKeyboardSelectionAndPreview", libraryInteraction.testThreeShelvesPersistCycleAndUseIndependentKeyboardSelectionAndPreview),
            ("testLibraryKeyboardGridRangesAllResultsFiltersAndEditingStayDistinct", libraryInteraction.testLibraryKeyboardGridRangesAllResultsFiltersAndEditingStayDistinct),
            ("testRapidQueriesCannotOverwriteLatestSearchAndRetainFocusOnMetadataChange", libraryInteraction.testRapidQueriesCannotOverwriteLatestSearchAndRetainFocusOnMetadataChange),
            ("testRemovingLastVisibleItemClearsInspectorAndFiltersRecoverSameScope", libraryInteraction.testRemovingLastVisibleItemClearsInspectorAndFiltersRecoverSameScope),
            ("testSubfolderTitleIncludesItsParentLikeWindows", libraryInteraction.testSubfolderTitleIncludesItsParentLikeWindows),
            ("testUnnamedItemTitlesAreTheTrimmedFirstLineAndLinkHostLikeWindows", libraryInteraction.testUnnamedItemTitlesAreTheTrimmedFirstLineAndLinkHostLikeWindows),
            ("testRemovingAnotherFolderKeepsTheOpenViewLikeWindows", libraryInteraction.testRemovingAnotherFolderKeepsTheOpenViewLikeWindows),
            ("testRestoringFromTrashSelectsTheFirstRemainingItemLikeWindows", libraryInteraction.testRestoringFromTrashSelectsTheFirstRemainingItemLikeWindows),
            ("testInspectorEditsPersistAndFailedSaveKeepsDraftAndSelection", libraryInteraction.testInspectorEditsPersistAndFailedSaveKeepsDraftAndSelection),
            ("testMixedTransferExportAndDragPreserveRepresentationsOrderAndOriginals", libraryInteraction.testMixedTransferExportAndDragPreserveRepresentationsOrderAndOriginals),
            ("testYouTubeParserIgnoresHTMLAndRejectsMalformedOrUntrustedImages", libraryInteraction.testYouTubeParserIgnoresHTMLAndRejectsMalformedOrUntrustedImages),
            ("testAddressClassificationRejectsPrivateTransitionAndNoncanonicalForms", publicLinks.testAddressClassificationRejectsPrivateTransitionAndNoncanonicalForms),
            ("testDestinationRequiresNamedHTTPSAndStripsFragmentWithoutLeakingSecrets", publicLinks.testDestinationRequiresNamedHTTPSAndStripsFragmentWithoutLeakingSecrets),
            ("testPinnedEndpointUsesNumericCaseButTLSAndHostHeaderUseOriginalHostname", publicLinks.testPinnedEndpointUsesNumericCaseButTLSAndHostHeaderUseOriginalHostname),
            ("testTLSRejectsAnUntrustedSelfSignedCertificateWithoutChangingSystemTrust", publicLinks.testTLSRejectsAnUntrustedSelfSignedCertificateWithoutChangingSystemTrust),
            ("testHTTPParserStreamsFixedChunkedAndConnectionCloseBodies", publicLinks.testHTTPParserStreamsFixedChunkedAndConnectionCloseBodies),
            ("testHTTPParserRejectsAmbiguousTruncatedCompressedAndOversizedResponses", publicLinks.testHTTPParserRejectsAmbiguousTruncatedCompressedAndOversizedResponses),
            ("testHTMLHonorsDeclaredMetaCharsetAndFallsBackToWindows1252", publicLinks.testHTMLHonorsDeclaredMetaCharsetAndFallsBackToWindows1252),
            ("testHTMLTitleKeepsJoinersButDropsControlsAndBidirectionalOverrides", publicLinks.testHTMLTitleKeepsJoinersButDropsControlsAndBidirectionalOverrides),
            ("testHTMLExtractsBoundedTextAndOneSafeThumbnailWithoutExecutingOrFollowingOtherResources", publicLinks.testHTMLExtractsBoundedTextAndOneSafeThumbnailWithoutExecutingOrFollowingOtherResources),
            ("testMetadataConcurrencyBackoffPrivateLinksAndUserTitle", libraryInteraction.testMetadataConcurrencyBackoffPrivateLinksAndUserTitle),
            ("testMetadataCancellationDoesNotWriteLateResultOrRevealShelf", libraryInteraction.testMetadataCancellationDoesNotWriteLateResultOrRevealShelf),
            ("testManualMetadataRefreshBypassesCacheAndKeepsUserTitle", libraryInteraction.testManualMetadataRefreshBypassesCacheAndKeepsUserTitle),
            ("testNewNoteClearsNarrowFiltersAndOpensEditableDetails", libraryInteraction.testNewNoteClearsNarrowFiltersAndOpensEditableDetails),
            ("testCancelledOldJobCannotClearOrOverwriteNewRequestForSameLink", libraryInteraction.testCancelledOldJobCannotClearOrOverwriteNewRequestForSameLink),
            ("testTenThousandRecordsQueryAndPagingStayBoundedWithThousandImages", libraryInteraction.testTenThousandRecordsQueryAndPagingStayBoundedWithThousandImages),
            ("testDatabaseSymlinksAndCorruptionNeverOverwriteOriginal", libraryInteraction.testDatabaseSymlinksAndCorruptionNeverOverwriteOriginal),
            ("testLibraryCopyUsesAllSelectedButPreviewCopyOnlyCurrentAndFailedCopyKeepsBoard", libraryInteraction.testLibraryCopyUsesAllSelectedButPreviewCopyOnlyCurrentAndFailedCopyKeepsBoard),
            ("testThreeLargeShelvesFitAvailableHeightWithoutChangingSavedSize", libraryInteraction.testThreeLargeShelvesFitAvailableHeightWithoutChangingSavedSize),
            ("testNativeLibraryOffscreenLayoutsInLightAndDarkAppearance", libraryInteraction.testNativeLibraryOffscreenLayoutsInLightAndDarkAppearance),
            ("testTextEditsPreserveIdentityDatePinOrderAndExportedCopy", interactions.testTextEditsPreserveIdentityDatePinOrderAndExportedCopy),
            ("testEditingRejectsCorruptArchiveAndSymlinkWithoutChangingData", interactions.testEditingRejectsCorruptArchiveAndSymlinkWithoutChangingData),
            ("testTextCopyFeedbackCoversSingleAndBatchCopies", interactions.testTextCopyFeedbackCoversSingleAndBatchCopies),
            ("testPinAndFavoritesShortcutsAreSymmetricAcrossShelves", interactions.testPinAndFavoritesShortcutsAreSymmetricAcrossShelves),
            ("testImagePreviewNavigationCopiesOnlyCurrentItemAndClampsAtEnds", interactions.testImagePreviewNavigationCopiesOnlyCurrentItemAndClampsAtEnds),
            ("testTextPreviewNavigationSavesAndCopiesCurrentEditedNote", interactions.testTextPreviewNavigationSavesAndCopiesCurrentEditedNote),
            ("testUnpinningInFilteredPreviewMovesToNeighborOrReportsEmpty", interactions.testUnpinningInFilteredPreviewMovesToNeighborOrReportsEmpty),
            ("testBorderlessTextPreviewSeparatesBrowsingAndEditingKeysAndFlushesEdits", interactions.testBorderlessTextPreviewSeparatesBrowsingAndEditingKeysAndFlushesEdits),
            ("testFailedTextSaveKeepsDraftForCorrection", interactions.testFailedTextSaveKeepsDraftForCorrection),
            ("testEditingMenuSelectsAndCopiesUnicodePreviewTextToPrivateClipboard", interactions.testEditingMenuSelectsAndCopiesUnicodePreviewTextToPrivateClipboard),
            ("testFastScrollDiscardsIntermediateWorkAndLoadsLatestRangeOffMainThread", interactions.testFastScrollDiscardsIntermediateWorkAndLoadsLatestRangeOffMainThread),
            ("testThumbnailBudgetDoesNotContinuouslyDecodeAnOversizedRange", interactions.testThumbnailBudgetDoesNotContinuouslyDecodeAnOversizedRange),
            ("testRecycledCardsDoNotReplayArrivalAnimations", interactions.testRecycledCardsDoNotReplayArrivalAnimations),
            ("testOpeningSettingsPreservesPreferencesHistoryAndSelection", settings.testOpeningSettingsPreservesPreferencesHistoryAndSelection),
            ("testSettingsBindingsApplyAppearanceWithoutMovingFocusOrDroppingHistory", settings.testSettingsBindingsApplyAppearanceWithoutMovingFocusOrDroppingHistory),
            ("testCompactMenuIdentifiesTheAppAndKeepsDailyActions", settings.testCompactMenuIdentifiesTheAppAndKeepsDailyActions),
            ("testSideRemovalUsesVisibleNewestLeftOrderAndConfirmationSnapshot", merge.testSideRemovalUsesVisibleNewestLeftOrderAndConfirmationSnapshot),
            ("testSizePersistsWithoutLosingHistoryOrThumbnailBounds", merge.testSizePersistsWithoutLosingHistoryOrThumbnailBounds),
            ("testRecordingFileTransfersPreserveMixedItemsWithoutReadingMovieBytes", merge.testRecordingFileTransfersPreserveMixedItemsWithoutReadingMovieBytes),
            ("testFolderCandidatesRejectSymlinksAndRestrictRecordings", merge.testFolderCandidatesRejectSymlinksAndRestrictRecordings),
            ("testGeneratedRecordingThumbnailAndPinnedExpiryKeepOriginal", merge.testGeneratedRecordingThumbnailAndPinnedExpiryKeepOriginal),
            ("testToggleShortcutValidationAndUpstreamLinkAreForkSafe", merge.testToggleShortcutValidationAndUpstreamLinkAreForkSafe),

            ("testShelfModesPersistAndTabPreservesBothSelections", dual.testShelfModesPersistAndTabPreservesBothSelections),
            ("testShiftArrowsAndEnterCopyEverySelectedImageInOrder", dual.testShiftArrowsAndEnterCopyEverySelectedImageInOrder),
            ("testTextRangeEnterCommandAAndDeleteAreSymmetric", dual.testTextRangeEnterCommandAAndDeleteAreSymmetric),
            ("testDeselectingFocusedItemStillCopiesOnlyRemainingSelection", dual.testDeselectingFocusedItemStillCopiesOnlyRemainingSelection),
            ("testOnlyPlainReturnUsesShelfCopyAndCloseWhileOtherCopyAndEditingRoutesStayOpen", dual.testOnlyPlainReturnUsesShelfCopyAndCloseWhileOtherCopyAndEditingRoutesStayOpen),
            ("testShelfCopyReportsSuccessOnlyAfterCopyingNonemptyImageTextAndLinkBatches", dual.testShelfCopyReportsSuccessOnlyAfterCopyingNonemptyImageTextAndLinkBatches),
            ("testNamedPasteboardContainsEveryImageAndFinderFileURL", dual.testNamedPasteboardContainsEveryImageAndFinderFileURL),
            ("testFailedTransferLeavesNamedPasteboardAndOriginalsUntouched", dual.testFailedTransferLeavesNamedPasteboardAndOriginalsUntouched),
            ("testTextPasteboardConcatenatesAllEntriesAndDragOffersAllFiles", dual.testTextPasteboardConcatenatesAllEntriesAndDragOffersAllFiles),
            ("testImageDragSnapshotIncludesSelectionAndUnselectedDragIsSingle", dual.testImageDragSnapshotIncludesSelectionAndUnselectedDragIsSingle),
            ("testTextDragRefusesSymlinkWithoutOverwritingTarget", dual.testTextDragRefusesSymlinkWithoutOverwritingTarget),
            ("testBorderlessPreviewHasNoFooterAndCannotZoomBelowFit", dual.testBorderlessPreviewHasNoFooterAndCannotZoomBelowFit),
            ("testPanelHeightKeepsBothRowsInsideVisibleScreen", dual.testPanelHeightKeepsBothRowsInsideVisibleScreen),

            ("testDefaultAndInvalidRetention", tests.testDefaultAndInvalidRetention),
            ("testEveryRetentionChoicePersists", tests.testEveryRetentionChoicePersists),
            ("testNewestFirstAndDuplicatesDoNotRenew", tests.testNewestFirstAndDuplicatesDoNotRenew),
            ("testRestartPreservesOrderAndDates", tests.testRestartPreservesOrderAndDates),
            ("testExpiryDeletesOwnedCopiesButKeepsOriginals", tests.testExpiryDeletesOwnedCopiesButKeepsOriginals),
            ("testCutoffAndFreshImage", tests.testCutoffAndFreshImage),
            ("testShorterRetentionAppliesImmediately", tests.testShorterRetentionAppliesImmediately),
            ("testMissingFilesArePruned", tests.testMissingFilesArePruned),
            ("testLegacyMigrationRecoversOnlyOwnedFilesOnce", tests.testLegacyMigrationRecoversOnlyOwnedFilesOnce),
            ("testOrphanFilesExpireAndLookalikesStay", tests.testOrphanFilesExpireAndLookalikesStay),
            ("testSymlinkIsNeverFollowedOrDeleted", tests.testSymlinkIsNeverFollowedOrDeleted),
            ("testSymlinkedInboxDoesNotDeleteFiles", tests.testSymlinkedInboxDoesNotDeleteFiles),
            ("testCorruptMetadataCanRecoverLegacyList", tests.testCorruptMetadataCanRecoverLegacyList),
            ("testLineKeepsMoreThanScreenCapacityAndBoundsThumbnails", tests.testLineKeepsMoreThanScreenCapacityAndBoundsThumbnails),
            ("testWheelBothDirectionsAndResizeClamp", tests.testWheelBothDirectionsAndResizeClamp),
            ("testNewCaptureReturnsToNewestAndExpiredLineClamps", tests.testNewCaptureReturnsToNewestAndExpiredLineClamps),
            ("testScrollLoadsVisibleThumbnailsAndEvictsOffscreenImages", tests.testScrollLoadsVisibleThumbnailsAndEvictsOffscreenImages),
            ("testLayoutStartsLeftAndLastCardIsReachable", tests.testLayoutStartsLeftAndLastCardIsReachable),
            ("testPanelRoutesSyntheticWheelLocally", tests.testPanelRoutesSyntheticWheelLocally),
            ("testClearPersistsAndDoesNotReimportOrphans", tests.testClearPersistsAndDoesNotReimportOrphans),
            ("testNestedClipboardNamesAreNotDeleted", tests.testNestedClipboardNamesAreNotDeleted),
            ("testSettingsOfferEveryDurationAndPersistSelection", tests.testSettingsOfferEveryDurationAndPersistSelection),
            ("testPinnedClipboardSurvivesExpiryAndRestart", favorites.testPinnedClipboardSurvivesExpiryAndRestart),
            ("testExternalPinCreatesPrivateCopyAndPreservesOriginal", favorites.testExternalPinCreatesPrivateCopyAndPreservesOriginal),
            ("testFavoritesFilterAndClearPreservePins", favorites.testFavoritesFilterAndClearPreservePins),
            ("testOldMetadataAndCorruptFavoritesRecovery", favorites.testOldMetadataAndCorruptFavoritesRecovery),
            ("testSymlinkFavoriteIsRejectedAndOriginalKept", favorites.testSymlinkFavoriteIsRejectedAndOriginalKept),
            ("testFailedExpiryAndTrashKeepRecordForRetry", favorites.testFailedExpiryAndTrashKeepRecordForRetry),
            ("testMultiSelectionRangeToggleCancelAndFilter", favorites.testMultiSelectionRangeToggleCancelAndFilter),
            ("testTrashConfirmationSnapshotKeepsOriginalAndIgnoresNewSelection", favorites.testTrashConfirmationSnapshotKeepsOriginalAndIgnoresNewSelection),
            ("testChangedFileBecomesSymlinkAndIsNeverTrashed", favorites.testChangedFileBecomesSymlinkAndIsNeverTrashed),
            ("testExportCollisionsCancelMissingAndSourcesUnchanged", favorites.testExportCollisionsCancelMissingAndSourcesUnchanged),
            ("testKeyboardSelectionCopyPreviewEscapeAndScroll", favorites.testKeyboardSelectionCopyPreviewEscapeAndScroll),
            ("testPanelKeyboardRequiresExplicitFocusAndStopsAfterClose", favorites.testPanelKeyboardRequiresExplicitFocusAndStopsAfterClose),
            ("testShortcutValidationPersistenceAndNoDefaultInterception", favorites.testShortcutValidationPersistenceAndNoDefaultInterception),
            ("testHotKeysCanCoexistAndConflictsPreserveRegistration", favorites.testHotKeysCanCoexistAndConflictsPreserveRegistration),
            ("testHotKeyEventsRouteToTheirOwnCallbackOnly", favorites.testHotKeyEventsRouteToTheirOwnCallbackOnly),
            ("testDisabledAndEnablingTextWatcherNeverImportsOldClipboard", textZoom.testDisabledAndEnablingTextWatcherNeverImportsOldClipboard),
            ("testUnicodeMultilineLongTextRoundTripsAndDoesNotChangeClipboard", textZoom.testUnicodeMultilineLongTextRoundTripsAndDoesNotChangeClipboard),
            ("testPrivateMarkersImageCompanionsAndFileCopiesAreSkippedBeforeReadingText", textZoom.testPrivateMarkersImageCompanionsAndFileCopiesAreSkippedBeforeReadingText),
            ("testOwnTextCopiesEmptyOversizedAndChangingClipboardAreSkipped", textZoom.testOwnTextCopiesEmptyOversizedAndChangingClipboardAreSkipped),
            ("testRecaptureMovesExistingExactTextToNewestWithoutGrowingHistory", textDedupStore.testRecaptureMovesExistingExactTextToNewestWithoutGrowingHistory),
            ("testRecaptureAndNewCaptureStayNewestWithAnUnchangedClock", textDedupStore.testRecaptureAndNewCaptureStayNewestWithAnUnchangedClock),
            ("testBackwardClockKeepsLatestCaptureFirstWithActualCaptureTime", textDedupStore.testBackwardClockKeepsLatestCaptureFirstWithActualCaptureTime),
            ("testBackwardClockUsesActualCaptureForExpiryWhilePinnedItemsRemain", textDedupStore.testBackwardClockUsesActualCaptureForExpiryWhilePinnedItemsRemain),
            ("testRecapturingFrontItemRefreshesTimeAndPreservesNamedPinAndOrganization", textDedupStore.testRecapturingFrontItemRefreshesTimeAndPreservesNamedPinAndOrganization),
            ("testRecaptureReturnsRetainedOffShelfTextAndInvalidatesOldRemovalUndo", textDedupStore.testRecaptureReturnsRetainedOffShelfTextAndInvalidatesOldRemovalUndo),
            ("testRecaptureNeverResurrectsAnExplicitlyTrashedRecord", textDedupStore.testRecaptureNeverResurrectsAnExplicitlyTrashedRecord),
            ("testImportedDuplicatesConsolidateOnRecaptureAndPreserveAllOrganization", textDedupStore.testImportedDuplicatesConsolidateOnRecaptureAndPreserveAllOrganization),
            ("testRecaptureDoesNotOverwriteNewerCustomNameOrNoteWithDuplicateMetadata", textDedupStore.testRecaptureDoesNotOverwriteNewerCustomNameOrNoteWithDuplicateMetadata),
            ("testNormalizedCopiesReuseIdentityAndPreserveNewestLiteralBytes", textDedupStore.testNormalizedCopiesReuseIdentityAndPreserveNewestLiteralBytes),
            ("testWhitespaceCaseAndInvisibleContentRemainDistinct", textDedupStore.testWhitespaceCaseAndInvisibleContentRemainDistinct),
            ("testNewlineOnlyCopiesNormalizeLineEndingsWithoutLosingLineCount", textDedupStore.testNewlineOnlyCopiesNormalizeLineEndingsWithoutLosingLineCount),
            ("testEditedTextIdentityTracksNewPayloadAndSurvivesRestart", textDedupStore.testEditedTextIdentityTracksNewPayloadAndSurvivesRestart),
            ("testExistingDatabaseBackfillsIdentityWithoutDeletingOrRewritingRecords", textDedupStore.testExistingDatabaseBackfillsIdentityWithoutDeletingOrRewritingRecords),
            ("testRestartRepairsIdentityAfterLegacyWriterEditsPayload", textDedupStore.testRestartRepairsIdentityAfterLegacyWriterEditsPayload),
            ("testVersionOneDigestMigrationPreservesPayloadsAndMatchesNormalizedRecopy", textDedupStore.testVersionOneDigestMigrationPreservesPayloadsAndMatchesNormalizedRecopy),
            ("testCurrentCaptureRepairsMissingIdentityAfterExternalLegacyWriterEdit", textDedupStore.testCurrentCaptureRepairsMissingIdentityAfterExternalLegacyWriterEdit),
            ("testNormalizedRecaptureRefreshesMaterializedFileWithNewestExactBytes", textDedupStore.testNormalizedRecaptureRefreshesMaterializedFileWithNewestExactBytes),
            ("testCanonicalOnlyEditRefreshesAdapterCopyAndMaterializedBytesWithoutDateChange", textDedupStore.testCanonicalOnlyEditRefreshesAdapterCopyAndMaterializedBytesWithoutDateChange),
            ("testNormalizedRecaptureRejectsUnsafeFilesAndRollsBackFileAfterDatabaseFailure", textDedupStore.testNormalizedRecaptureRejectsUnsafeFilesAndRollsBackFileAfterDatabaseFailure),
            ("testFailedConsolidationRollsBackRowsMembershipsIdentitySearchAndRevision", textDedupStore.testFailedConsolidationRollsBackRowsMembershipsIdentitySearchAndRevision),
            ("testRecaptureRenewsTemporaryRetentionFromMostRecentCopy", textDedupStore.testRecaptureRenewsTemporaryRetentionFromMostRecentCopy),
            ("testExactTextLookupUsesDigestIndexInsteadOfScanningPayloads", textDedupStore.testExactTextLookupUsesDigestIndexInsteadOfScanningPayloads),
            ("testRecopyMovesExistingStableRecordToFrontAndPersistsNewestCapture", textDedupLegacy.testRecopyMovesExistingStableRecordToFrontAndPersistsNewestCapture),
            ("testRecopyAtFrontStillRefreshesTimestampAndSucceeds", textDedupLegacy.testRecopyAtFrontStillRefreshesTimestampAndSucceeds),
            ("testRecopyNormalizesEquivalentTextButPreservesWhitespaceCaseAndInvisibleDifferences", textDedupLegacy.testRecopyNormalizesEquivalentTextButPreservesWhitespaceCaseAndInvisibleDifferences),
            ("testNormalizedRecopyRefreshesMaterializedFileAndPreservesNamedPin", textDedupLegacy.testNormalizedRecopyRefreshesMaterializedFileAndPreservesNamedPin),
            ("testNormalizedRecopyRejectsUnsafeFilesAndRestoresFileAfterArchiveFailure", textDedupLegacy.testNormalizedRecopyRejectsUnsafeFilesAndRestoresFileAfterArchiveFailure),
            ("testRecopyPreservesPinnedNameAndLeavesMaterializedFilesAlone", textDedupLegacy.testRecopyPreservesPinnedNameAndLeavesMaterializedFilesAlone),
            ("testRecopyCollapsesOnlyMatchingLegacyDuplicatesKeepingNewestIDAndMetadata", textDedupLegacy.testRecopyCollapsesOnlyMatchingLegacyDuplicatesKeepingNewestIDAndMetadata),
            ("testArchiveFailureLeavesEntriesFocusSelectionScrollAndFilesUnchanged", textDedupLegacy.testArchiveFailureLeavesEntriesFocusSelectionScrollAndFilesUnchanged),
            ("testMarkupSharesTopRowAndFreesBottomCanvas", unifiedMarkup.testMarkupSharesTopRowAndFreesBottomCanvas),
            ("testNarrowToolbarKeepsEveryToolAndNavigationReachableInOneRow", unifiedMarkup.testNarrowToolbarKeepsEveryToolAndNavigationReachableInOneRow),
            ("testStylePopoverKeepsNativeKeyOwnershipAndAppliesDrawingStyles", unifiedMarkup.testStylePopoverKeepsNativeKeyOwnershipAndAppliesDrawingStyles),
            ("testOverflowActionsAndFailedDoneKeepDraftAndAllowRetry", unifiedMarkup.testOverflowActionsAndFailedDoneKeepDraftAndAllowRetry),
            ("testFinishingAndReusingPanelRemoveMarkupAccessoryAndClosePopovers", unifiedMarkup.testFinishingAndReusingPanelRemoveMarkupAccessoryAndClosePopovers),
            ("testTextRetentionPinFavoritesAndRestartUseSharedDuration", textZoom.testTextRetentionPinFavoritesAndRestartUseSharedDuration),
            ("testTextTrashFailureRetriesWithoutLosingArchive", textZoom.testTextTrashFailureRetriesWithoutLosingArchive),
            ("testCorruptTextArchiveAndSymlinkArePreserved", textZoom.testCorruptTextArchiveAndSymlinkArePreserved),
            ("testTextKeyboardAndWheelDoNotChangeImageScrollOrTriggerImageActions", textZoom.testTextKeyboardAndWheelDoNotChangeImageScrollOrTriggerImageActions),
            ("testZoomBoundsResetAndInvalidDeltas", textZoom.testZoomBoundsResetAndInvalidDeltas),
            ("testZoomedImageMouseDragPansBothAxesAndClampsWithoutMovingWindow", textZoom.testZoomedImageMouseDragPansBothAxesAndClampsWithoutMovingWindow),
            ("testPreviewWheelZoomAndResetStayLocal", textZoom.testPreviewWheelZoomAndResetStayLocal)
        ]
        for (name, test) in cases {
            let before = assertionFailures
            do { try test() }
            catch { fail("\(name): \(error)", file: #filePath, line: #line) }
            if assertionFailures == before { print("PASS \(name)") }
        }
        print("\(cases.count) synthetic history/layout cases, \(assertionFailures) failures")
        if assertionFailures != 0 { exit(1) }
    }
}
