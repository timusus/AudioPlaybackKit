# Player conformance mapping: media3 ExoPlayerTest to PlaybackPlayer

Each row is one `@Test` method of media3's `ExoPlayerTest`
(`libraries/exoplayer/src/test/java/androidx/media3/exoplayer/ExoPlayerTest.java` on main at `cd36f10d2e8e`, its last change before 12 October 2026)
and where `Tests/PlaybackPlayerTests` (or `Tests/PlaybackNowPlayingTests`, for available commands) covers it: a named test, `n/a` with the reason, or `gap` for a
rule of ours that has no test yet. A **deviation** is behaviour ADR-0019 chose to do differently; the row
says what we do. A ported test cites its media3 test in a comment, so `grep` finds the pair both ways.

To port a test: drive the same scenario on `PlayerRig` (items are ten seconds at 8 Hz on the fake
output), assert what media3 asserts in our terms (`itemTransition` for `onMediaItemTransition`, `state`
for `onPlaybackStateChanged`, `seekLanded` for a seek's `onPositionDiscontinuity`), and update the row.

`n/a` reasons used below: **API** (a media3 class, listener, command or setting with no counterpart:
`PlayerMessage`, device volume, audio session ids, metadata, release, Wear output
checks), **internal** (renderers, track selection, load control, scheduling, offload, period holders),
**timeline** (`Timeline` windows and periods, live, `MediaSource` composition; the player has a flat item
list), **masking** (media3 masks state while its playback thread catches up; `Player` writes the list,
index and position on the call and holds stale transport events, see `PlayerTransportEventTests`),
**range** (an index past the list or a seek on an empty list: `Player` traps, the app owns the list),
**ads**, **video**, **shuffle** (the app's, ADR-0019 queue features), **session** (ducking and delayed
focus gain: iOS ducks another app's audio, or pauses ours, in the system, so the player sees only an
interruption), **effects** (silence skipping is an app processor).

The session rules map media3's audio focus onto `AVAudioSession`: a transient loss is an interruption,
a permanent loss is an interruption that ends without `shouldResume`, regaining focus is reactivating
the session, abandoning it is deactivating, and becoming noisy is `oldDeviceUnavailable` losing a
personal output. `PlayerSessionTests` drives them through `FakeAudioSession`.

## ExoPlayerTest

| media3 test | Ours |
|---|---|
| `playEmptyTimeline` | n/a: API, an empty list is `.idle` and there is no `prepare` |
| `playSinglePeriodTimeline` | `PlayerTransportEventTests.testTheEndOfTheListEndsOnTheLastItem` |
| `playMultiPeriodTimeline` | n/a: timeline |
| `play_audioVideoAudioVideoTransition_videoSizeChangedCalledCorrectly` | n/a: video |
| `playShortDurationPeriods` | n/a: timeline |
| `renderersLifecycle_renderersThatAreNeverEnabled_areNotReset` | n/a: internal |
| `renderersLifecycle_setForegroundMode_resetsDisabledRenderersThatHaveBeenEnabled` | n/a: internal |
| `renderersLifecycle_selectTextTracksWhilePlaying_textRendererEnabledAndReset` | n/a: video |
| `renderersLifecycle_seekTo_resetsDisabledRenderersIfRequired` | n/a: internal |
| `renderersLifecycle_onlyRenderersThatAreEnabled_areSetToFinal` | n/a: internal |
| `trackSelectorLifeCycle_whenReleasedFromApplicationThread_throwsIllegalStateException` | n/a: internal |
| `trackSelectorLifeCycle_usedBySecondPlayerBeforeRelease_throwsIllegalStateException` | n/a: internal |
| `trackSelectorLifeCycle_usedBySecondPlayerAfterRelease_worksAsExpected` | n/a: internal |
| `readAheadToEndDoesNotResetRenderer` | n/a: internal |
| `playWithAds_withPerStreamMediaProgressionEnabled_doesNotAdvanceReadingPeriodPerStream` | n/a: ads |
| `rendererError_withPerStreamMediaProgressionEnabledAndNullMediaPeriodId_setsCorrectMediaPeriodOnError` | n/a: internal |
| `rendererError_inAdvancedPeriodWithPerStreamMediaProgressionEnabled_doesNotDisruptCurrentPlayback` | n/a: internal |
| `rendererError_inThirdPeriodWhileEarliestReadingPeriodIsSecondPeriod_doesNotDisruptFirstOrSecondPeriodPlayback` | n/a: internal |
| `play_withNonPreparedPeriodAndPartialRendererTransitionBeforePrepared_enablesAllRenderersOncePrepared` | n/a: internal |
| `play_withNonPreparedPeriodAndCompleteRendererTransitionBeforePrepared_enablesAllRenderersOncePrepared` | n/a: internal |
| `playLiveStreams_withPerStreamMediaProgressionEnabled_doesNotAdvanceReadingPeriodPerStream` | n/a: internal |
| `resettingMediaSourcesGivesFreshSourceInfo` | n/a: timeline |
| `repeatModeChanges` | `PlayerAdvanceTests.testRepeatOneReplaysTheCurrentItemUntilItIsTurnedOff` |
| `shuffleModeEnabledChanges` | n/a: shuffle |
| `periodHoldersReleasedAfterSeekWithRepeatModeAll` | n/a: internal |
| `seekTo_indexLargerThanPlaylist_isIgnored` | n/a: range |
| `addMediaItems_indexLargerThanPlaylist_addsToEndOfPlaylist` | n/a: range |
| `removeMediaItems_fromIndexLargerThanPlaylist_isIgnored` | n/a: range |
| `removeMediaItems_toIndexLargerThanPlaylist_removesUpToEndOfPlaylist` | n/a: range |
| `moveMediaItems_fromIndexLargerThanPlaylist_isIgnored` | n/a: range |
| `moveMediaItems_toIndexLargerThanPlaylist_movesItemsUpToEndOfPlaylist` | n/a: range |
| `moveMediaItems_newIndexLargerThanPlaylist_movesItemsUpToEndOfPlaylist` | n/a: range |
| `seekDiscontinuity` | `PlayerTransportEventTests.testSeekLandedIsSentOnceTheSeeksAudioIsHeard` |
| `seekDiscontinuityWithAdjustment` | n/a: API |
| `internalDiscontinuityAtNewPosition` | n/a: internal |
| `internalDiscontinuityAtInitialPosition` | n/a: internal |
| `allActivatedTrackSelectionAreReleasedForSinglePeriod` | n/a: internal |
| `setTrackSelectionParameters_rapidUpdate_notifiesSequentially` | n/a: internal |
| `allActivatedTrackSelectionAreReleasedForMultiPeriods` | n/a: internal |
| `allActivatedTrackSelectionAreReleasedWhenTrackSelectionsAreRemade` | n/a: internal |
| `allActivatedTrackSelectionAreReleasedWhenTrackSelectionsAreReused` | n/a: internal |
| `setTrackSelectionParameters_onlyAffectingReadingPeriodMediaItem_selectsCorrectTracks` | n/a: internal |
| `trackReselection_withPerStreamMediaProgressionAndReadingAhead_recreatesReadingPeriods` | n/a: internal |
| `dynamicTimelineChangeReason` | n/a: timeline |
| `resetMediaSourcesWithPositionResetAndShufflingUsesFirstPeriod` | n/a: timeline |
| `setPlaybackSpeedBeforePreparationCompletesSucceeds` | n/a: API |
| `seekBeforePreparationCompletes_seeksToCorrectPosition` | n/a: masking |
| `stop_correctMasking` | n/a: masking |
| `stopWhileLoading_correctMaskingIsLoading` | n/a: masking |
| `stop_releasesMediaSource` | n/a: internal |
| `stop_withLiveStream_currentPeriodIsPlaceholder` | n/a: timeline |
| `stop_withVodStream_currentPeriodIsPlaceholder` | n/a: timeline |
| `playbackError_withLiveStream_currentPeriodIsPlaceholder` | n/a: timeline |
| `release_correctMasking` | n/a: masking |
| `releaseWhileLoading_correctMaskingIsLoading` | n/a: masking |
| `settingNewStartPositionPossibleAfterStopAndClearMediaItems` | `PlayerCoreTests.testSetItemsStartsAtTheGivenIndexAndPosition` |
| `resetPlaylistWithPreviousPosition` | n/a: API, `setItems` always takes a start index and position (`PlayerCoreTests.testSetItemsStartsAtTheGivenIndexAndPosition`) |
| `resetPlaylistStartsFromDefaultPosition` | `PlayerCoreTests.testSetItemsStartsAtTheGivenIndexAndPosition` |
| `resetPlaylistWithoutResettingPositionStartsFromOldPosition` | `PlayerEditTests.testReplaceItemsWithTheSameCurrentItemKeepsThePosition`; `replaceItems` is the no-reset form |
| `stopAndClearMediaItemsDuringPreparationOverwritesPreparation` | n/a: masking |
| `stopAndSeekAfterStopDoesNotResetTimeline` | `PlayerTransportEventTests.testSeeksAndSkipsAfterStopStayIdleUntilPlay` |
| `reprepareAfterPlaybackError` | `PlayerCoreTests.testACurrentItemThatFailsToOpenIsIdleWithAnErrorAndPlayRetries` |
| `seekAndReprepareAfterPlaybackError_keepsSeekPositionAndTimeline` | `PlayerErrorTests.testASeekAfterAFailureWaitsForPlayAndPlaysFromTheTarget` |
| `restartAfterEmptyTimelineWithShuffleModeEnabledUsesCorrectFirstPeriod` | n/a: shuffle |
| `playbackErrorAndReprepareDoesNotResetPosition` | `PlayerErrorTests.testACurrentItemFailingMidStreamStopsThereAndPlayRetriesFromThePosition` |
| `seekAfterPlaybackError` | `PlayerErrorTests.testASeekAfterAFailureWaitsForPlayAndPlaysFromTheTarget` |
| `playbackErrorAndReprepareWithPositionResetKeepsWindowSequenceNumber` | n/a: internal |
| `playbackErrorTwiceStillKeepsTimeline` | n/a: timeline |
| `sendMessagesDuringPreparation` | n/a: API |
| `sendMessagesAfterPreparation` | n/a: API |
| `multipleSendMessages` | n/a: API |
| `sendMessagesFromStartPositionOnlyOnce` | n/a: API |
| `multipleSendMessagesAtSameTime` | n/a: API |
| `sendMessagesMultiPeriodResolution` | n/a: API |
| `sendMessagesAtStartAndEndOfPeriod` | n/a: API |
| `sendMessagesSeekOnDeliveryTimeDuringPreparation` | n/a: API |
| `sendMessagesSeekOnDeliveryTimeAfterPreparation` | n/a: API |
| `sendMessagesSeekAfterDeliveryTimeDuringPreparation` | n/a: API |
| `sendMessagesSeekAfterDeliveryTimeAfterPreparation` | n/a: API |
| `sendMessagesRepeatDoesNotRepost` | n/a: API |
| `sendMessagesRepeatWithoutDeletingDoesRepost` | n/a: API |
| `sendMessagesMoveCurrentMediaItemIndex` | n/a: API |
| `sendMessagesMultiWindowDuringPreparation` | n/a: API |
| `sendMessagesMultiWindowAfterPreparation` | n/a: API |
| `sendMessagesMoveMediaItemIndex` | n/a: API |
| `sendMessagesNonLinearPeriodOrder` | n/a: API |
| `cancelMessageBeforeDelivery` | n/a: API |
| `cancelRepeatedMessageAfterDelivery` | n/a: API |
| `sendMessages_withMediaRemoval_triggersCorrectMessagesAndDoesNotThrow` | n/a: API |
| `setAndSwitchSurface` | n/a: video |
| `switchSurfaceOnEndedState` | n/a: video |
| `timelineUpdateDropsPrebufferedPeriods` | n/a: timeline |
| `timelineUpdateWithNewMidrollAdCuePoint_dropsPrebufferedPeriod` | n/a: ads |
| `timelineUpdateWithPostroll_transitionToMultiPeriod_doesNotGetStuck` | n/a: ads |
| `seekPastBufferingMidroll_playsAdAndThenContentFromSeekPosition` | n/a: ads |
| `repeatedSeeksToUnpreparedPeriodInSameWindowKeepsWindowSequenceNumber` | n/a: internal |
| `invalidSeekFallsBackToSubsequentPeriodOfTheRemovedPeriod` | n/a: range |
| `onPlayerErrorChanged_isNotifiedForNullError` | n/a: API, `error` is an observed property |
| `recursivePlayerChangesReportConsistentValuesForAllListeners` | n/a: API |
| `recursivePlayerChangesAreReportedInCorrectOrder` | n/a: API |
| `recursiveTimelineChangeInStopAreReportedInCorrectOrder` | n/a: API |
| `clippedLoopedPeriodsArePlayedFully` | n/a: timeline |
| `updateTrackSelectorThenSeekToUnpreparedPeriod_returnsEmptyTrackGroups` | n/a: internal |
| `removingLoopingLastPeriodFromPlaylistDoesNotThrow` | n/a: timeline |
| `seekToUnpreparedWindowWithNonZeroOffsetInConcatenationStartsAtCorrectPosition` | n/a: timeline |
| `seekToUnpreparedWindowWithMultiplePeriodsInConcatenationStartsAtCorrectPeriod` | n/a: timeline |
| `periodTransitionReportsCorrectBufferedPosition` | n/a: API, no buffered position |
| `setPlaybackSpeedConsecutivelyNotifiesListenerForEveryChangeOnceAndIsMasked` | n/a: API |
| `setUnsupportedPlaybackSpeedConsecutivelyNotifiesListenerForEveryChangeOnceAndResetsOnceHandled` | n/a: API |
| `setUnsupportedPlaybackSpeedDirectlyFollowedByDisablingTheRendererAndSupportedPlaybackSpeed_keepsCorrectFinalSpeedAndInformsListenersCorrectly` | n/a: internal |
| `simplePlaybackHasNoPlaybackSuppression` | `PlayerCoreTests.testIsPlayingOnlyWhenReadyIntendedAndNotSuppressed` |
| `audioFocus_transientLossDuckWhilePlaying_continuesPlaybackWithLowerVolume` | n/a: session |
| `audioFocus_transientLossDuckAndGainWhilePlaying_restoresOriginalVolume` | n/a: session |
| `audioFocus_transientLossDuckWhilePaused_lowersVolume` | n/a: session |
| `audioFocus_transientLossDuckAndGainWhilePaused_restoresOriginalVolume` | n/a: session |
| `audioFocus_lossWhileSleepingForOffload_disablesSleeping` | n/a: internal |
| `delegatingMediaSourceApproach` | n/a: timeline |
| `seekTo_mediaItemIndexIsReset_deprecated` | n/a: masking |
| `seekTo_mediaItemIndexIsReset` | n/a: masking |
| `seekTo_singlePeriod_correctMaskingPosition` | n/a: masking |
| `seekTo_singlePeriod_beyondBufferedData_correctMaskingPosition` | n/a: masking |
| `seekTo_backwardsSinglePeriod_correctMaskingPosition` | n/a: masking |
| `seekTo_backwardsMultiplePeriods_correctMaskingPosition` | n/a: masking |
| `seekTo_toUnbufferedPeriod_correctMaskingPosition` | n/a: masking |
| `seekTo_toLoadingPeriod_correctMaskingPosition` | n/a: masking |
| `seekTo_toLoadingPeriod_withinPartiallyBufferedData_correctMaskingPosition` | n/a: masking |
| `seekTo_toLoadingPeriod_beyondBufferedData_correctMaskingPosition` | n/a: masking |
| `seekTo_toInnerFullyBufferedPeriod_correctMaskingPosition` | n/a: masking |
| `addMediaSource_withinBufferedPeriods_correctMaskingPosition` | n/a: masking |
| `moveMediaItem_behindLoadingPeriod_correctMaskingPosition` | n/a: masking |
| `moveMediaItem_undloadedBehindPlaying_correctMaskingPosition` | n/a: masking |
| `removeMediaItem_removePlayingWindow_correctMaskingPosition` | n/a: masking |
| `removeMediaItem_removeLoadingWindowWithReadingPeriodSingleAdvancement_correctMaskingPosition` | n/a: internal |
| `removeMediaItem_removeLoadingWindowWithReadingPeriodDoubleAdvancement_correctMaskingPosition` | n/a: internal |
| `removeMediaItem_removeInnerFullyBufferedWindow_correctMaskingPosition` | n/a: masking |
| `clearMediaItems_correctMaskingPosition` | n/a: masking |
| `becomingNoisyIgnoredIfBecomingNoisyHandlingIsDisabled` | n/a: API, the route rule is always on |
| `pausesWhenBecomingNoisyIfBecomingNoisyHandlingIsEnabled` | `PlayerSessionTests.testHeadphonesUnpluggedPausesWithRouteLost` |
| `nextLoadPositionExceedingLoadControlMaxBuffer_whileCurrentLoadInProgress_doesNotThrowException` | n/a: internal |
| `moveMediaItem` | `PlayerEditTests.testMoveTheCurrentAndMoveAcrossItKeepPlaying` |
| `removeMediaItem` | `PlayerEditTests.testRemoveALaterItemReArmsTheNext` |
| `removeMediaItems` | n/a: API, `remove(at:)` takes one index |
| `clearMediaItems` | `PlayerEditTests.testRemoveAllWhilePlayingStopsAndLeavesIdle`; **deviation**, an empty list is `.idle` (ADR-0019 State), not `.ended` |
| `multipleModificationWithRecursiveListenerInvocations` | n/a: API |
| `modifyPlaylistUnprepared_remainsInIdle_needsPrepareForBuffering` | n/a: API, no `prepare`; `setItems` prepares |
| `addMediaSource_toEndedPlaylist_remainsInEndedAndNeedsSeekForBuffering` | `PlayerAdvanceTests.testAddingToAnEndedListStaysEndedUntilASeek` |
| `addMediaSource_toEmptyPreparedPlaylist_startsBuffering` | `PlayerEditTests.testInsertIntoAnEmptyListSetsIt` |
| `addMediaSources_afterSeekOnEmptyPreparedPlaylist_startsBufferingAtRequestedPosition` | n/a: range |
| `addMediaSources_afterInvalidSeekOnEmptyPreparedPlaylist_remainsInEndedState` | n/a: range |
| `clearMediaItemsAndSeek_inStateEnded_remainsInEnded` | `PlayerEditTests.testClearAndSeekWhileEndedLeavesIdle`; **deviation**, an empty list is `.idle` (ADR-0019 State), not `.ended`, and the seek is ignored |
| `stop_modifyingPlaylistRemainsInIdleState_needsPrepareForBuffering` | `PlayerEditTests.testEditsAfterStopStayIdleUntilPlay`; seeks and skips in `PlayerTransportEventTests.testSeeksAndSkipsAfterStopStayIdleUntilPlay` |
| `prepareWithInvalidInitialSeek_expectEndedImmediately` | n/a: range |
| `prepareWhenAlreadyPreparedIsANoop` | n/a: API, no `prepare` |
| `prepare_preloadingEnabledRepeatModeOne_sameWindowPeriodCreatedForPreloading` | `PlayerAdvanceTests.testRepeatOneReplaysTheCurrentItemUntilItIsTurnedOff`; the same entry is armed again |
| `prepare_preloadingEnabled_nextWindowPeriodPreloaded` | `PlayerCoreTests.testSetItemsArmsTheCurrentThenTheNextInTheFactorysCallOrder` |
| `prepare_preloadingDisabled_nextWindowPeriodNotPreloaded` | n/a: API, the next is always pre-armed for the gapless handoff |
| `seekToIndexLargerThanNumberOfPlaylistItems` | n/a: range |
| `seekToIndexWithEmptyMultiWindowMediaSource` | n/a: timeline |
| `emptyMultiWindowMediaSource_doesNotEnterBufferState` | n/a: timeline |
| `seekToIndexWithEmptyMultiWindowMediaSource_usesLazyPreparation` | n/a: timeline |
| `timelineUpdateInMultiWindowMediaSource_removingPeriod_withUnpreparedMaskingMediaPeriod_doesNotThrow` | n/a: masking |
| `setPlayWhenReady_keepsCurrentPosition` | n/a: masking |
| `setPlayWhenReady_correctPositionMasking` | n/a: masking |
| `setShuffleMode_correctPositionMasking` | n/a: shuffle |
| `setShuffleOrder_keepsCurrentPosition` | n/a: shuffle |
| `setShuffleOrder_notifiesTimelineChanged` | n/a: shuffle |
| `setShuffleOrder_shuffleOrderLengthNotEqualToCurrentPlaylistLength_shouldThrow` | n/a: shuffle |
| `setMediaSources_empty_whenEmpty_correctMaskingMediaItemIndex` | n/a: masking |
| `setMediaItems_resetPosition_resetsPosition` | `PlayerCoreTests.testSetItemsStartsAtTheGivenIndexAndPosition` |
| `setMediaSources_empty_whenEmpty_validInitialSeek_correctMaskingMediaItemIndex` | n/a: masking |
| `setMediaSources_empty_whenEmpty_invalidInitialSeek_correctMaskingMediaItemIndex` | n/a: range |
| `setMediaSources_whenEmpty_correctMaskingMediaItemIndex` | n/a: masking |
| `setMediaSources_whenEmpty_validInitialSeek_correctMasking` | n/a: masking |
| `setMediaSources_whenEmpty_invalidInitialSeek_correctMasking` | n/a: range |
| `setMediaSources_correctMaskingMediaItemIndex` | n/a: masking |
| `setMediaSources_whenIdle_correctMaskingPlaybackState` | n/a: masking |
| `setMediaSources_whenIdle_invalidSeek_correctMaskingPlaybackState` | n/a: range |
| `setMediaSources_whenIdle_noSeek_correctMaskingPlaybackState` | n/a: masking |
| `setMediaSources_whenIdle_noSeekEmpty_correctMaskingPlaybackState` | n/a: masking |
| `setMediaSources_whenEnded_correctMaskingPlaybackState` | n/a: masking |
| `setMediaSources_whenEnded_invalidSeek_correctMaskingPlaybackState` | n/a: range |
| `setMediaSources_whenEnded_noSeek_correctMaskingPlaybackState` | n/a: masking |
| `setMediaSources_whenEnded_noSeekEmpty_correctMaskingPlaybackState` | n/a: masking |
| `setMediaSources_whenPrepared_correctMaskingPlaybackState` | n/a: masking |
| `setMediaSources_whenPrepared_invalidSeek_correctMaskingPlaybackState` | n/a: range |
| `setMediaSourcesWhileLoading_noSeekEmpty_correctMaskingIsLoading` | n/a: masking |
| `addMediaSources_whenEmptyInitialSeek_correctPeriodMasking` | n/a: masking |
| `addMediaSources_skipSettingMediaItems_validInitialSeek_correctMasking` | n/a: masking |
| `addMediaSources_skipSettingMediaItems_invalidInitialSeek_correctMaskingMediaItemIndex` | n/a: range |
| `moveMediaItems_correctMaskingMediaItemIndex` | n/a: masking |
| `moveMediaItems_unprepared_correctMaskingMediaItemIndex` | n/a: masking |
| `removeMediaItems_correctMaskingMediaItemIndex` | n/a: masking |
| `removeMediaItems_currentItemRemoved_correctMasking` | `PlayerEditTests.testRemoveTheCurrentPlaysItsSuccessorFromTheStart` |
| `removeMediaItems_currentItemRemovedThatIsTheLast_correctMasking` | `PlayerEditTests.testRemoveTheCurrentWhenItIsLastEndsAtTheFirstItem` |
| `removeMediaItemsWhileLoading_currentItemRemovedThatIsTheLast_correctMaskingIsLoading` | n/a: masking |
| `removeMediaItems_removeTailWithCurrentWindow_whenIdle_finishesPlayback` | n/a: masking |
| `clearMediaItems_correctMasking` | n/a: masking |
| `clearMediaItems_unprepared_correctMaskingMediaItemIndex_notEnded` | n/a: masking |
| `errorThrownDuringPlaylistUpdate_keepsConsistentPlayerState` | n/a: timeline |
| `seekToCurrentPosition_inEndedState_switchesToBufferingStateAndContinuesPlayback` | `PlayerAdvanceTests.testASeekInAnEndedListPlaysOnIntoAnAddedItem` |
| `pauseAtEndOfMediaItems_pausesPlaybackBeforeTransitioningToTheNextItem` | `PlayerAdvanceTests.testPauseAtEndOfItemLandsPausedAtTheStartOfTheNext`; **deviation**: media3 pauses at the end of the item and moves on at `play`; ADR-0019 moves to the next item and pauses at its 0, so the UI shows what `play` starts |
| `pauseAtEndOfMediaItems_pausesPlaybackWhenEnded` | `PlayerAdvanceTests.testPauseAtEndOfTheLastItemEnds` |
| `loading_withLargeAllocationCausingOom_playsRemainingMediaAndThenThrows` | n/a: internal |
| `seekTo_withEmptyTimeline_emitsPositionDiscontinuityEvent` | n/a: timeline |
| `seekTo_whileReady_callsOnIsPlayingChanged` | `PlayerTransportEventTests.testASeekWhilePlayingBuffersThenPlays` |
| `multipleListenersAndMultipleCallbacks_callbacksAreOrderedByType` | n/a: API |
| `playlistWithMediaWithStartOffsets_andStartOffsetChangesDuringPreparation_appliesCorrectRenderingOffsetToAllPeriods` | n/a: timeline |
| `mediaItemOfSources_correctInTimelineWindows` | n/a: timeline |
| `setMediaSource_notifiesMediaItemTransition` | n/a: **deviation**, `setItems` sends no `itemTransition`: the app made the change (ADR-0019 Edits) |
| `setMediaSource_replaceWithSameMediaItem_notifiesMediaItemTransition` | n/a: **deviation**, as `setMediaSource_notifiesMediaItemTransition` |
| `automaticWindowTransition_notifiesMediaItemTransition` | `PlayerTransportEventTests.testCrossingIntoTheNextAdvancesAndArmsTheOneAfter` |
| `clearMediaItems_notifiesMediaItemTransition` | `PlayerEditTests.testRemoveAllWhilePlayingStopsAndLeavesIdle` |
| `seekTo_otherWindow_notifiesMediaItemTransition` | `PlayerCoreTests.testSeekToALaterAndAnEarlierItemSetsItCurrent` |
| `seekTo_sameWindow_doesNotNotifyMediaItemTransition` | `PlayerTransportEventTests.testASeekWithinTheItemSendsNoTransition` |
| `seekToNextPrevious_singleItemRepeat_notifiesMediaItemTransition` | `PlayerAdvanceTests.testASkipThatWrapsOntoTheSameItemRestartsItAsATransition` |
| `repeat_notifiesMediaItemTransition` | `PlayerAdvanceTests.testRepeatAllWithOneItemIsARepeat` |
| `stop_doesNotNotifyMediaItemTransition` | `PlayerTransportEventTests.testSeeksAndSkipsAfterStopStayIdleUntilPlay` |
| `timelineRefresh_withModifiedMediaItem_doesNotNotifyMediaItemTransition` | n/a: timeline |
| `isCommandAvailable_isTrueForAvailableCommands` | `NowPlayingCommandTests.testPlayPauseIsAvailableWithNoItemAndAnswersNoActionableItem`, `testSeekingIsUnavailableUntilTheItemOpens`; available commands are the enabled remote commands |
| `isCommandAvailable_withDeviceVolumeControlEnabled_isTrueForDeviceVolumeCommands` | n/a: API |
| `isCommandAvailable_withoutDeviceVolumeControlEnabled_isFalseForDeviceVolumeCommands` | n/a: API |
| `isCommandAvailable_duringAd_isFalseForSeekCommands` | n/a: ads |
| `isCommandAvailable_duringUnseekableItem_isFalseForSeekInCurrentCommands` | `NowPlayingCommandTests.testSeekingIsUnavailableForALiveItem`; an item without a duration is the unseekable one |
| `isCommandAvailable_duringUnseekableLiveItem_isFalseForSeekToPrevious` | n/a: API, `previousTrack` is `SEEK_TO_PREVIOUS_MEDIA_ITEM`, which ignores seekability |
| `isCommandAvailable_duringUnseekableLiveItemWithPreviousWindow_isTrueForSeekToPrevious` | n/a: API, as above |
| `isCommandAvailable_duringLiveItem_isTrueForSeekToNext` | n/a: API, `nextTrack` is `SEEK_TO_NEXT_MEDIA_ITEM` |
| `seekTo_nextWindow_notifiesAvailableCommandsChanged` | `NowPlayingCommandTests.testNextAndPreviousFollowTheCurrentIndex` |
| `seekTo_previousWindow_notifiesAvailableCommandsChanged` | `NowPlayingCommandTests.testNextAndPreviousFollowTheCurrentIndex` |
| `seekTo_sameWindow_doesNotNotifyAvailableCommandsChanged` | n/a: API, the command centre has no change notification |
| `automaticWindowTransition_notifiesAvailableCommandsChanged` | `NowPlayingCommandTests.testAnAutomaticAdvanceToTheLastItemDisablesNext` |
| `addMediaSource_atTheEnd_notifiesAvailableCommandsChanged` | `NowPlayingCommandTests.testEditsAroundTheCurrentItemUpdateNextAndPrevious` |
| `addMediaSource_atTheStart_notifiesAvailableCommandsChanged` | `NowPlayingCommandTests.testEditsAroundTheCurrentItemUpdateNextAndPrevious` |
| `removeMediaItem_atTheEnd_notifiesAvailableCommandsChanged` | `NowPlayingCommandTests.testEditsAroundTheCurrentItemUpdateNextAndPrevious` |
| `removeMediaItem_atTheStart_notifiesAvailableCommandsChanged` | `NowPlayingCommandTests.testEditsAroundTheCurrentItemUpdateNextAndPrevious` |
| `removeMediaItem_current_notifiesAvailableCommandsChanged` | `NowPlayingCommandTests.testRemovingTheCurrentItemUpdatesNextAndPrevious` |
| `setRepeatMode_all_notifiesAvailableCommandsChanged` | `NowPlayingCommandTests.testRepeatAllEnablesNextAndPreviousAtTheEndsAndRepeatOneDoesNot` |
| `setRepeatMode_one_doesNotNotifyAvailableCommandsChanged` | `NowPlayingCommandTests.testRepeatAllEnablesNextAndPreviousAtTheEndsAndRepeatOneDoesNot` |
| `setShuffleModeEnabled_notifiesAvailableCommandsChanged` | n/a: shuffle |
| `mediaSourceMaybeThrowSourceInfoRefreshError_isNotThrownUntilPlaybackReachedFailingItem` | `PlayerErrorTests.testANextTheFactoryRejectsIsReportedWhenPlaybackReachesIt` |
| `mediaPeriodMaybeThrowPrepareError_isNotThrownUntilPlaybackReachedFailingItem` | `PlayerErrorTests.testANextThatFailsToOpenIsReportedWhenPlaybackReachesIt` |
| `mediaPeriodMaybeThrowPrepareError_bufferedDurationUnderMinimumBufferForPlayback_keepPlayingUntilBufferedDataExhausts` | `PlayerErrorTests.testANextThatFailsToOpenIsReportedWhenPlaybackReachesIt` |
| `sampleStreamMaybeThrowError_isNotThrownUntilPlaybackReachedFailingItem` | `PlayerErrorTests.testANextFailingWhileDecodedAheadIsReportedWhenPlaybackReachesIt` |
| `sampleStreamMaybeThrowError_bufferedDurationUnderMinimumBufferForPlayback_keepPlayingUntilBufferedDataExhausts` | `PlayerErrorTests.testANextFailingWhileDecodedAheadIsReportedWhenPlaybackReachesIt` |
| `rendererError_isReportedWithReadingMediaPeriodId` | n/a: internal |
| `play_withDynamicSchedulingEnabled_usesRendererDurationSchedulingInterval` | n/a: internal |
| `play_withDynamicSchedulingDisabled_usesDefaultSchedulingInterval` | n/a: internal |
| `play_withDynamicSchedulingEnabledAndMultipleRenderers_usesMinimumDurationSchedulingInterval` | n/a: internal |
| `prepareOnly_withDynamicSchedulingEnabled_usesDefaultIdleSchedulingInterval` | n/a: internal |
| `play_withDynamicSchedulingEnabledAndInBufferingState_usesBufferingSchedulingInterval` | n/a: internal |
| `play_withDynamicSchedulingEnabled_wakesUpExoPlayerForWork` | n/a: internal |
| `getCurrentPosition_withDynamicSchedulingEnabled_calculatesUsingEstimatedPosition` | n/a: internal |
| `getCurrentPosition_withDynamicSchedulingEnabledAndPaused_calculatedPositionIsNotExtrapolated` | n/a: internal |
| `getCurrentPosition_withDynamicSchedulingEnabledAndPlayThenPaused_returnsMaskedEstimatedPosition` | n/a: internal |
| `getCurrentPosition_withDynamicSchedulingEnabledAndStopped_returnsMaskedEstimatedPosition` | n/a: internal |
| `getCurrentPosition_withDynamicSchedulingEnabledAndSpeedChangedBeforeClockAdvance_calculatesCorrectPositionEstimate` | n/a: internal |
| `getCurrentPosition_withDynamicSchedulingEnabledAndSpeedChangedAfterClockAdvance_calculatesCorrectPositionEstimate` | n/a: internal |
| `getCurrentPosition_withDynamicSchedulingEnabled_enforcesMonotonicPositionTracking` | n/a: internal |
| `getCurrentPosition_withDynamicSchedulingEnabled_playAfterPauseDoesNotExtrapolateBeforeInternalThreadCatchesUp` | n/a: internal |
| `play_backwardSeekWithDynamicScheduling_reportsCorrectTargetInDiscontinuityCallback` | n/a: internal |
| `enablingOffload_withAudioOnly_playerSleeps` | n/a: internal |
| `enablingOffloadDuringPlayback_withAudioOnly_playerSleeps` | n/a: internal |
| `enableOffloadScheduling_whenPlayerSleeps_callsOnSleepingForOffloadChanged` | n/a: internal |
| `enableOffloadScheduling_whenOffloadIsDisabled_renderingResumes` | n/a: internal |
| `enablingOffload_withFastReadingPeriodAdvancement_playerDoesNotSleep` | n/a: internal |
| `wakeupListenerWhileSleepingForOffload_isWokenUp_renderingResumes` | n/a: internal |
| `enableOffload_duringSleepGetCurrentPosition_returnsEstimatedPosition` | n/a: internal |
| `enableOffload_pauseAndSeekDuringSleep_currentPositionIsSeekedPosition` | n/a: internal |
| `enableOffload_seekThenPauseDuringSleep_returnsEstimatePositionByPauseTime` | n/a: internal |
| `playerIdle_withSetPlaybackSpeed_usesPlaybackParameterSpeedWithPitchUnchanged` | n/a: API |
| `setPlaybackSpeed_withAdPlayback_onlyAppliesToContent` | n/a: ads |
| `onEvents_correspondToListenerCalls` | n/a: API |
| `repeatMode_windowTransition_callsOnPositionDiscontinuityAndOnMediaItemTransition` | `PlayerAdvanceTests.testRepeatOneReplaysTheCurrentItemUntilItIsTurnedOff`, `PlayerAdvanceTests.testRepeatAllWrapsFromTheLastItemToTheFirst` |
| `setMediaSources_removesPlayingPeriod_callsOnPositionDiscontinuity` | n/a: API, no discontinuity callback |
| `onPositionDiscontinuity_recursiveStateChange_mediaItemMaskingCorrect` | n/a: API |
| `removeMediaItems_removesPlayingPeriod_callsOnPositionDiscontinuity` | `PlayerEditTests.testRemoveTheCurrentPlaysItsSuccessorFromTheStart` |
| `concatenatingMediaSourceRemoveMediaSource_removesPlayingPeriod_callsOnPositionDiscontinuity` | n/a: timeline |
| `concatenatingMediaSourceRemoveMediaSourceWithSeek_overridesRemoval_callsOnPositionDiscontinuity` | n/a: timeline |
| `setMediaItems_callsListenersWithSameInstanceOfMediaItem` | n/a: API |
| `seekTo_callsOnPositionDiscontinuity` | `PlayerTransportEventTests.testSeekLandedIsSentOnceTheSeeksAudioIsHeard` |
| `seekTo_whenTimelineEmpty_callsOnPositionDiscontinuityAndSetsCorrectIndices` | n/a: range |
| `seekBack_callsOnPositionDiscontinuity` | `PlayerCoreTests.testSeekByClampsToTheItem` |
| `seekBack_pastZero_seeksToZero` | `PlayerCoreTests.testSeekByClampsToTheItem` |
| `seekForward_callsOnPositionDiscontinuity` | `PlayerCoreTests.testSeekByClampsToTheItem` |
| `seekForward_pastDuration_seeksToDuration` | `PlayerCoreTests.testSeekByClampsToTheItem` |
| `seekToPrevious_withPreviousWindowAndCloseToStart_seeksToPreviousWindow` | `PlayerCoreTests.testSkipToNextAndPrevious` |
| `seekToPrevious_notCloseToStart_seeksToZero` | n/a: **deviation**, no 3 s threshold: `skipToPrevious` always goes to the previous item and a restart is `seek(to: 0)` |
| `seekToNext_withNextWindow_seeksToNextWindow` | `PlayerCoreTests.testSkipToNextAndPrevious` |
| `seekToNext_liveWindowWithoutNextWindow_seeksToLiveEdge` | n/a: timeline |
| `stop_doesNotCallOnPositionDiscontinuity` | n/a: API |
| `seekTo_cancelsSourceDiscontinuity_callsOnPositionDiscontinuity` | n/a: API |
| `setMediaItem_withMediaMetadata_updatesMediaMetadata` | n/a: API |
| `playingMedia_withNoMetadata_doesNotUpdateMediaMetadata` | n/a: API |
| `builder_inBackgroundThreadWithAllowedAnyThreadMethods_doesNotThrow` | n/a: API |
| `onPlaylistMetadataChanged_calledWhenPlaylistMetadataSet` | n/a: API |
| `release_triggersAllPendingEventsInAnalyticsListeners` | n/a: API |
| `releaseAfterRendererEvents_triggersPendingVideoEventsInListener` | n/a: video |
| `releaseAfterVolumeChanges_triggerPendingVolumeEventInListener` | n/a: API |
| `releaseAfterMuting_triggerPendingVolumeEventInListener` | n/a: API |
| `release_internalFailure_noTimeoutError` | n/a: API |
| `releaseAfterVolumeChanges_triggerPendingDeviceVolumeEventsInListener` | n/a: API |
| `setDeviceMutedWithoutDeviceVolumeControl_noEffectDeviceRemainsUnmuted` | n/a: API |
| `setDeviceMutedWithDeviceVolumeControl_deviceGetsMuted` | n/a: API |
| `increaseDeviceVolumeWithoutDeviceVolumeControl_deviceVolumeUnchanged` | n/a: API |
| `decreaseDeviceVolumeWithoutDeviceVolumeControl_deviceVolumeUnchanged` | n/a: API |
| `getDeviceVolumeWithoutDeviceVolumeControl_returnsZero` | n/a: API |
| `getDeviceInfoWithoutDeviceVolumeControl_returnsZeroForMinMaxVolume` | n/a: API |
| `mutingSequence_triggersVolumeEventsInListenerWhenAppropriate` | n/a: API |
| `unmutingSequence_triggersVolumeEventsInListenerWhenAppropriate` | n/a: API |
| `loadControlBackBuffer_withInsufficientMemoryLimits_stillContinuesPlayback` | n/a: internal |
| `rendererError_whileReadingAhead_isReportedAfterMediaItemTransition` | `PlayerErrorTests.testANextFailingWhileDecodedAheadIsReportedWhenPlaybackReachesIt` |
| `rendererError_whileReadingAheadAndOverlappingWithOtherDiscontinuity_isReportedAfterMediaItemTransition` | n/a: internal |
| `play_withReadingAheadWithNewRenderer_enablesButNotStartsNewRenderer` | n/a: internal |
| `play_withReadingAheadWithNewRendererAndPausing_enablesButNotStartsNewRenderer` | n/a: internal |
| `replaceMediaItems_notReplacingCurrentItem_correctMasking` | `PlayerEditTests.testReplaceItemsWithTheSameCurrentItemKeepsThePosition` |
| `replaceMediaItems_replacingCurrentItem_correctMasking` | `PlayerEditTests.testReplaceItemsWithAnotherCurrentItemRestarts` |
| `replaceMediaItems_replacingCurrentItemWithEmptyListAndSubsequentItem_correctMasking` | n/a: masking |
| `replaceMediaItems_replacingCurrentItemWithEmptyListAndNoSubsequentItem_correctMasking` | n/a: masking |
| `replaceMediaItems_fromPreparedEmpty_correctMasking` | n/a: masking |
| `replaceMediaItems_fromEmptyToEmpty_doesNothing` | n/a: API |
| `replaceMediaItems_withInvalidToIndex_correctMasking` | n/a: masking |
| `replaceMediaItems_withOnlyPartiallyReplaceableItemsInMediaSource_createsNewItems` | n/a: internal |
| `replaceMediaItems_withReplaceableItemsInMediaSourceBeforePreparation_updatesMediaItems` | n/a: internal |
| `replaceMediaItems_withReplaceableItemsInMediaSourceImmediatelyAfterPreparation_updatesMediaItems` | n/a: internal |
| `replaceMediaItems_withReplaceableItemsInMediaSourceDuringPlayback_updatesMediaItemsWithoutInterruption` | n/a: internal |
| `play_withOnlyUnsuitableOutputsOnWear_shouldSuppressPlayback` | n/a: API |
| `play_withAtleastOneSuitableOutputOnWear_shouldNotSuppressPlayback` | n/a: API |
| `play_callMultipleTimesOnUnsuitableOutputFollowedByPause_shouldRetainSameSuppressionReason` | n/a: API |
| `play_onBuiltinSpeakerWithoutWearPresentAsSystemFeature_shouldNotSuppressPlayback` | n/a: API |
| `play_withOnlyUnsuitableOutputsWithoutEnablingPlaybackSuppression_shouldNotSuppressPlayback` | n/a: API |
| `addSuitableOutputWhenPlaybackSuppressed_shouldRemovePlaybackSuppression` | n/a: API |
| `addUnsuitableOutputWhenPlaybackIsSuppressed_shouldNotRemovePlaybackSuppression` | n/a: API |
| `addSuitableOutputWhenPlaybackNotSuppressed_shouldNotRemovePlaybackSuppression` | n/a: API |
| `removeAllSuitableOutputsWhenPlaybackOngoing_shouldSetPlaybackSuppression` | n/a: API |
| `removeAnyUnsuitableOutputWhenPlaybackOngoing_shouldNotSetPlaybackSuppression` | n/a: API |
| `removeAnySuitableOutputButOneSuitableDeviceStillConnected_shouldNotSetPlaybackSuppression` | n/a: API |
| `verifySuitableOutput_shouldSuppressPlaybackWhenNoSuitableOutputAvailable` | n/a: API |
| `verifySuitableOutput_shouldNotSuppressPlaybackWhenSuitableOutputIsAvailable` | n/a: API |
| `verifySuitableOutput_playbackSuppressionOnUnsuitableOutputDisabled_shouldNotSuppressPlayback` | n/a: API |
| `verifySuitableOutput_shouldRemovePlaybackSuppressionOnAdditionOfSuitableOutput` | n/a: API |
| `verifySuitableOutput_shouldSuppressPlaybackOnRemovalOfSuitableOutput` | n/a: API |
| `verifySuitableOutput_shouldSuppressPlaybackAgainAfterRemovalOfAddedSuitableOutput` | n/a: API |
| `pauseAtEndOfMediaItem_withSecondStreamDelayed_playsSuccessfully` | n/a: internal |
| `newlyEnabledRendererMidPlayback_receivesCurrentPlaybackPositionAsStartTime` | n/a: internal |
| `newlyEnabledRenderer_timelineIsSetBeforeEnable` | n/a: internal |
| `changeMediaItemMidPlayback_rendererReceivesNewTimelineBeforeStreamChange` | n/a: internal |
| `changeMediaItemMidPlayback_preparesSuccessfully` | n/a: internal |
| `silenceSkipped_playerEmitOnPositionDiscontinuity` | n/a: effects |
| `silenceSkipped_atItemTransition_doesNotHideAutoTransitionDiscontinuity` | n/a: effects |
| `seekToZeroAndTrackSelection_withNonZeroDefaultPosition_startsPlaybackAtZero` | n/a: internal |
| `repeatingItemWithSameStaticMetadata_keepsMetadata` | n/a: API |
| `setPriority_blocksOtherLowPriorityTasksInPriorityTaskManager` | n/a: internal |
| `setPriority_allowsOtherHighPriorityTasksInPriorityTaskManager` | n/a: internal |
| `setPriority_sendsSetPriorityMessageToRenderers` | n/a: API |
| `timelineUpdate_currentWindowNoLongerExists_movesToNextWindow` | n/a: timeline |
| `timelineUpdate_allPeriodsInCurrentWindowChange_keepsCurrentWindow` | n/a: timeline |
| `playbackErrorAndReprepare_withLiveTimelineAllPeriodsReplaced_keepsPlayingLiveSource` | n/a: timeline |
| `setAlarmAudioWithDeviceVolumeControl_exoPlayerIsConstructedWithNoDeviceUpdates` | n/a: API |
| `playWhenReadyChanges_areForwardedToTrackSelection` | n/a: internal |
| `playbackSpeedChanges_areForwardedToTrackSelection` | n/a: internal |
| `builderBuild_createsInitialAudioSessionId` | n/a: API |
| `setAudioSessionId_withDefinedId_updatesGetterAndListener` | n/a: API |
| `setAudioSessionId_withUndefinedId_updatesGetterAndListener` | n/a: API |
| `audioSessionId_manuallySet_isNotOverwrittenByBackgroundGeneration` | n/a: API |
| `audioSessionIdChangeInTheAudioSink_propagatesToRenderersAndListener` | n/a: internal |
| `multipleAudioSessionIdChangesOnPlayer_propagatesToRenderersAndListener` | n/a: internal |
| `multipleAudioRenderers_listenerRegisteredOnEnabledRendererOnly` | n/a: internal |
| `listenerUpdatedOnRendererSwitch` | n/a: internal |
| `multipleAudioSessionIdChangesOnAudioRenderer_propagatesToRenderersAndListener` | n/a: internal |
| `audioSessionIdChangeInDefaultAudioSinkAndPlayer_onlyCreatesAudioTrackOnce` | n/a: API |
| `builderBuild_propagatesAudioSessionIdToRenderersBeforeOnEnabled` | n/a: internal |
| `setVideoScalingMode_isSetOnPrimaryAndSecondaryVideoRenderers` | n/a: video |
| `play_withRecoverableErrorAfterAdvancingReadingPeriod_advancesPlayingPeriodWhileErrorHandling` | n/a: internal |
| `prepareMaskingMediaSource_withRealSourcePrepareError_reportsPlaybackException` | n/a: masking |
| `rendererReadToEndButNotReady_whilePaused_keepsCallingRenderFrequently` | n/a: internal |
| `clearMediaItems_afterReady_transitionsToEnded` | `PlayerEditTests.testRemoveAllWhilePlayingStopsAndLeavesIdle`; **deviation**, an empty list is `.idle` (ADR-0019 State), not `.ended` |
| `settingMediaItems_withEmptyListAfterReady_transitionsToEnded` | `PlayerEditTests.testSetItemsEmptyWhilePlayingStopsAndLeavesIdle`; **deviation**, `setItems([])` is `.idle`, not `.ended` |
| `setSeekBackIncrementMs_updatesSeekBackIncrementAndCallsListener` | n/a: API |
| `setSeekForwardIncrementMs_updatesSeekForwardIncrementAndCallsListener` | n/a: API |
| `setMaxSeekToPreviousPositionMs_updatesMaxSeekToPreviousPositionAndCallsListener` | n/a: API, no threshold (see `seekToPrevious_notCloseToStart_seeksToZero`) |
| `setVirtualDeviceId_forwardsIdToAudioSink` | n/a: API |
| `setAudioOutputProvider_forwardsProviderToAudioSink` | n/a: API |
| `seekToNonZeroMediaItemIndex_withInitialEmptyMediaSourceNoPositionReset_appliesSeekToFirstNonEmptyTimeline` | n/a: timeline |
| `seekToNonZeroMediaItemIndex_withInitialEmptyMediaSourceWithPositionReset_resetsStartIndexToZero` | n/a: timeline |
| `positionDiscontinuityFromInternalPlayer_whilePlaylistAlreadyCleared_isNotReported` | `PlayerTransportEventTests.testAStaleStatusInFlightAcrossASkipIsDropped`; a stale transport event is dropped |
| `removeMediaItem_withRepeatModeOne_endsPlaybackAndStopsLoading` | `PlayerAdvanceTests.testRemovingTheCurrentUnderRepeatOneEnds` |
| `removeMediaItem_withShuffleModeEnabledAndAvailableItemsWhenShuffling_continuesPlayback` | n/a: shuffle |
| `transitionIntoLiveStream_withUpdatedTimeline_doesNotCauseBuffering` | n/a: timeline |

## AudioFocusManagerTest

media3's `libraries/common/src/test/java/androidx/media3/common/audio/AudioFocusManagerTest.java` on
main at `c1a51872970d` (10 February 2026), in the terms above. A `_v26` variant maps with its pair.

| media3 test | Ours |
|---|---|
| `setAudioAttributes_withNullUsage_doesNotManageAudioFocus` | n/a: API, the player always manages the session |
| `setAudioAttributes_withNullUsage_abandonsAudioFocus` | n/a: API |
| `setAudioAttributes_withNullUsage_abandonsAudioFocus_v26` | n/a: API |
| `setAudioAttributes_withUsageAlarm_throwsIllegalArgumentException` | n/a: API |
| `setAudioAttributes_withUsageMedia_usesAudioFocusGain` | `PlayerSessionTests.testTheFirstPlayActivatesOnceBeforeTheTransportPlays` |
| `setAudioAttributes_inEndedState_requestsAudioFocus` | n/a: API, the configuration is fixed at init |
| `updateAudioFocus_idleToBuffering_setsPlayerCommandPlayWhenReady` | `PlayerSessionTests.testTheFirstPlayActivatesOnceBeforeTheTransportPlays` |
| `updateAudioFocus_pausedToPlaying_setsPlayerCommandPlayWhenReady` | `PlayerSessionTests.testTheFirstPlayActivatesOnceBeforeTheTransportPlays` |
| `updateAudioFocus_pausedToPlaying_withTransientDuck_setsPlayerCommandPlayWhenReady` | n/a: session |
| `updateAudioFocus_pausedToPlayingWithTransientLossAndDelayedGain_setsPlayerCommandPlayWhenReady` | n/a: session |
| `updateAudioFocus_pausedToPlayingWithTransientLossAndDelayedGainWithLaterLoss_sendsDoNotPlayAndAbandonsFocus` | n/a: session |
| `updateAudioFocus_pausedToPlayingWithTransientLossAndNoGain_setsPlayerCommandDoNotPlay` | `PlayerSessionTests.testAPlayDuringAnInterruptionThatCannotActivateStaysSuppressed`; **deviation**, `playWhenReady` stays true, suppressed, so the interruption's end can resume |
| `updateAudioFocus_pausedToPlayingWithTransientLossAndRegularGain_setsPlayerCommandPlayWhenReady` | `PlayerSessionTests.testAPlayDuringAnInterruptionReactivatesAndPlays` |
| `updateAudioFocus_toPausedBeforeRequestingFocus_setsPlayerCommandPlayWhenReady` | `PlayerSessionTests.testPauseAndStopBeforeAnyPlayLeaveTheSessionAlone` |
| `updateAudioFocus_toPausedWithFocus_setsPlayerCommandPlayWhenReady` | `PlayerSessionTests.testTheFirstPlayActivatesOnceBeforeTheTransportPlays` |
| `updateAudioFocus_toPausedWithFocusLoss_setsPlayerCommandDoNotPlay` | `PlayerSessionTests.testInterruptionEndedWithoutShouldResumeSetsPlayWhenReadyFalse` |
| `updateAudioFocus_toPausedWithTransientFocusLoss_setsPlayerCommandWaitForCallback` | `PlayerSessionTests.testAnInterruptionWhilePausedNeitherSuppressesNorResumes` |
| `updateAudioFocus_toPausedWithTransientFocusLossCanDuck_setsPlayerCommandPlayWhenReady` | n/a: session |
| `updateAudioFocus_abandonFocusWhenDucked_restoresFullVolume` | n/a: session |
| `updateAudioFocus_readyToIdle_abandonsAudioFocus` | `PlayerSessionTests.testStopDeactivatesAndTheNextPlayActivatesAgain` |
| `updateAudioFocus_readyToIdle_abandonsAudioFocus_v26` | `PlayerSessionTests.testStopDeactivatesAndTheNextPlayActivatesAgain` |
| `updateAudioFocus_readyToIdle_withoutFocus_isNoOp` | `PlayerSessionTests.testPauseAndStopBeforeAnyPlayLeaveTheSessionAlone` |
| `updateAudioFocus_readyToIdle_withoutFocus_isNoOp_v26` | `PlayerSessionTests.testPauseAndStopBeforeAnyPlayLeaveTheSessionAlone` |
| `onAudioFocusChange_withDuckEnabled_reducesAndRestoresVolume` | n/a: session |
| `onAudioFocusChange_withPausedWhenDucked_sendsCommandWaitForCallback` | n/a: session, `.spokenAudio` asks the system to pause instead of duck, which arrives as an interruption |
| `onAudioFocusChange_withTransientLoss_sendsCommandWaitForCallback` | `PlayerSessionTests.testInterruptionBeganSuppressesAndPausesTheTransport` |
| `onAudioFocusChange_withFocusLoss_sendsDoNotPlayAndAbandonsFocus` | `PlayerSessionTests.testInterruptionEndedWithoutShouldResumeSetsPlayWhenReadyFalse` |
| `onAudioFocusChange_withFocusLoss_sendsDoNotPlayAndAbandonsFocus_v26` | `PlayerSessionTests.testInterruptionEndedWithoutShouldResumeSetsPlayWhenReadyFalse` |
| `release_doesNotCallPlayerControlToRestoreVolume` | n/a: API |

## MediaSessionPlayerTest and MediaControllerTest

The media3 tests of a session routing controller commands to its player, and of what a controller
reads back, from `libraries/test_session_current/src/androidTest/java/androidx/media3/session/` at
`cd36f10d2e8e`. `NowPlayingSession` is the session: a remote command is a controller command, and
`MPNowPlayingInfoCenter` is what the controller reads. Only the tests with an iOS counterpart are listed;
the rest drive media3 API (custom layouts, browsing, playlist metadata, volume) with none.

| media3 test | Ours |
|---|---|
| `MediaSessionPlayerTest.play` | `NowPlayingCommandTests.testPlayAndPauseSetPlayWhenReady` |
| `MediaSessionPlayerTest.pause` | `NowPlayingCommandTests.testPlayAndPauseSetPlayWhenReady` |
| `MediaSessionPlayerTest.executeCommandButtonAction_playPauseWithoutParam_togglesPlayWhenReady` | `NowPlayingCommandTests.testTogglePausesWhilePlayingAndPlaysWhilePaused`, `testTogglePlaysOnEndedFromTheStart`, `testTogglePlaysWhileSuppressed` (`Util.shouldShowPlayButton`, `playIfSuppressed` true) |
| `MediaSessionPlayerTest.seekTo` | `NowPlayingCommandTests.testChangePlaybackPositionSeeks` |
| `MediaSessionPlayerTest.setPlaybackSpeed` | `NowPlayingCommandTests.testChangePlaybackRateSetsTheRate` |
| `MediaSessionPlayerTest.seekToNextMediaItem` | `NowPlayingCommandTests.testNextAndPreviousSkip` |
| `MediaSessionPlayerTest.seekToPreviousMediaItem` | `NowPlayingCommandTests.testNextAndPreviousSkip` |
| `MediaSessionPlayerTest.seekForward` | `NowPlayingCommandTests.testSkipsSeekByTheirInterval`; the interval is the app's `SkipMode`, not the player's |
| `MediaSessionPlayerTest.seekBack` | `NowPlayingCommandTests.testSkipsSeekByTheirInterval` |
| `MediaControllerTest.isCommandAvailable_withAvailableCommand_returnsTrue` | `NowPlayingCommandTests.testTracksModeEnablesNextAndPreviousAndNoSkips`, `testIntervalsModeEnablesSkipsWithTheirIntervalsAndNoTracks` |
| `MediaControllerTest.isCommandAvailable_withUnavailableCommand_returnsFalse` | `NowPlayingCommandTests.testChangePlaybackRateIsEnabledOnlyWithSupportedRates` |
| `MediaControllerTest.getMediaMetadata` | `NowPlayingInfoTests.testAnItemPublishesItsMetadataDurationElapsedAndRate` |
| `MediaControllerTest.getCurrentPosition_whenPlaying_advances` | `NowPlayingInfoTests.testAnItemPublishesItsMetadataDurationElapsedAndRate`; the system extrapolates from elapsed time and rate |
| `MediaControllerTest.getCurrentPosition_whenNotPlaying_doesNotAdvance` | `NowPlayingInfoTests.testPauseWritesTheElapsedTimeAndRateZero` |
| `MediaControllerTest.getCurrentPosition_afterPause_returnsCorrectPosition` | `NowPlayingInfoTests.testPauseWritesTheElapsedTimeAndRateZero` |

Rules of the session with no media3 test: elapsed time and rate are written only on a seek, a play or
pause, a rate change or an item change (`NowPlayingInfoTests.testPositionPumpsWriteNothing` and the
seek, rate, skip, advance and repeat tests); a forward seek under a second while playing is not seen,
since the player sends no seek the session can share. Artwork for an item no longer current is dropped
(`testArtworkThatArrivesAfterTheItemChangedIsDropped`), and `release()` disables every command
(`NowPlayingCommandTests.testReleaseDisablesEveryCommandAndClearsTheInfo`).

## Ours without a media3 test

Rules of ADR-0019 that media3 has no single test for: `PlayerAdvanceTests` `testTurningRepeatOffAtTheLastItemEnds`,
`testSkipsWrapUnderRepeatAllAndTreatRepeatOneAsOff`, `testPlayOnEndedRestartsTheCurrentItemFromZero`,
`testPauseAtEndOfItemSetLatePausesTheNextAtItsStart`, `testACrossingIntoANextArmedBeforeAnEditIsReportedByItsIndex`
(a **deviation**: media3 re-buffers onto the inserted item; the transport has already joined into the one
armed before the edit, so that one plays and the index follows it), `testACrossingIntoARemovedNextPlaysTheListsNext`,
`testRemovingTheCurrentLastItemUnderRepeatAllPlaysTheFirst`; `PlayerErrorTests`
`testANextTheFactoryRejectsIsReportedWhenPlaybackReachesIt` and `testAFailedNextTheAppRemovesIsNeverReported`.
