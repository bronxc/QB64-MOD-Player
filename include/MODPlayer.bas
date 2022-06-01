'---------------------------------------------------------------------------------------------------------
' QB64 MOD Player
' Copyright (c) 2022 Samuel Gomes
'---------------------------------------------------------------------------------------------------------

'---------------------------------------------------------------------------------------------------------
' HEADER FILES
'---------------------------------------------------------------------------------------------------------
'$Include:'MODPlayer.bi'
'---------------------------------------------------------------------------------------------------------

$If MODPLAYER_BM = UNDEFINED Then
    $Let MODPLAYER_BM = TRUE

    '-----------------------------------------------------------------------------------------------------
    ' Small test code for debugging the library. Comment the line below to disable debugging
    '-----------------------------------------------------------------------------------------------------
    '$Let MODPLAYER_DEBUG = TRUE
    $If MODPLAYER_DEBUG = DEFINED Then
            '$Debug
            If LoadMODFile("C:\Users\samue\OneDrive\Documents\GitHub\QB64-MOD-Player\mods\rez-monday.mod") Then
            StartMODPlayer
            Do
            Locate 1, 1
            Print Using "Order: ### / ###    Pattern: ### / ###    Row: ## / 64    BPM: ###    Speed: ###"; Song.orderPosition + 1; Song.orders; Order(Song.orderPosition) + 1; Song.highestPattern + 1; Song.patternRow + 1; Song.bpm; Song.speed;
            Limit 60
            Loop While KeyHit <> 27 Or Song.isPlaying
            StopMODPlayer
            End If
            End
    $End If

    '-----------------------------------------------------------------------------------------------------
    ' FUNCTIONS & SUBROUTINES
    '-----------------------------------------------------------------------------------------------------
    ' Calculates and sets the timer speed and also the mixer buffer update size
    ' We always set the global BPM using this and never directly
    Sub UpdateMODTimer (nBPM As Unsigned Byte)
        Song.bpm = nBPM

        ' Calculate the mixer buffer update size
        Song.mixerBufferSize = (Song.mixerRate * 5) / (2 * Song.bpm)

        ' S / (2 * B / 5) (where S is second and B is BPM)
        On Timer(Song.qb64Timer, 5 / (2 * Song.bpm)) MODPlayerTimerHandler
    End Sub


    ' Loads the MOD file into memory and prepares all required gobals
    Function LoadMODFile` (sFileName As String)
        ' By default we assume a failure
        LoadMODFile = FALSE

        ' Check if the file exists
        If Not FileExists(sFileName) Then Exit Function

        ' Attempt to open the file
        Dim fileHandle As Long
        fileHandle = FreeFile

        Open sFileName For Binary Access Read As fileHandle

        ' Check what kind of MOD file this is
        ' Seek to offset 1080 (438h) in the file & read in 4 bytes
        Dim i As Unsigned Integer
        Get fileHandle, 1081, Song.subtype

        ' Also, seek to the beginning of the file and get the song title
        Get fileHandle, 1, Song.songName

        Song.channels = 0
        Song.samples = 0

        Select Case Song.subtype
            Case "FEST", "FIST", "LARD", "M!K!", "M&K!", "M.K.", "N.T.", "NSMS", "PATT"
                Song.channels = 4
                Song.samples = 31
            Case "OCTA", "OKTA"
                Song.channels = 8
                Song.samples = 31
            Case Else
                ' Parse the subtype string to check for more variants
                If Right$(Song.subtype, 3) = "CHN" Then
                    ' Check xCNH types
                    Song.channels = Val(Left$(Song.subtype, 1))
                    Song.samples = 31
                ElseIf Right$(Song.subtype, 2) = "CH" Or Right$(Song.subtype, 2) = "CN" Then
                    ' Check for xxCH & xxCN types
                    Song.channels = Val(Left$(Song.subtype, 2))
                    Song.samples = 31
                ElseIf Left$(Song.subtype, 3) = "FLT" Or Left$(Song.subtype, 3) = "TDZ" Or Left$(Song.subtype, 3) = "EXO" Then
                    ' Check for FLTx, TDZx & EXOx types
                    Song.channels = Val(Right$(Song.subtype, 1))
                    Song.samples = 31
                ElseIf Left$(Song.subtype, 2) = "CD" And Right$(Song.subtype, 1) = "1" Then
                    ' Check for CDx1 types
                    Song.channels = Val(Mid$(Song.subtype, 3, 1))
                    Song.samples = 31
                ElseIf Left$(Song.subtype, 2) = "FA" Then
                    ' Check for FAxx types
                    Song.channels = Val(Right$(Song.subtype, 2))
                    Song.samples = 31
                Else
                    ' Extra checks for 15 sample MOD
                    For i = 1 To Len(Song.songName)
                        If isprint(Asc(Song.songName, i)) = 0 And Asc(Song.songName, i) <> NULL Then
                            ' This is probably not a 15 sample MOD file
                            Close fileHandle
                            Exit Function
                        End If
                    Next
                    Song.channels = 4
                    Song.samples = 15
                    Song.subtype = "MO15" ' Change subtype to reflect 15-sample mod, otherwise it will contain garbage
                End If
        End Select

        ' Sanity check
        If (Song.samples = 0 Or Song.channels = 0) Then
            Close fileHandle
            Exit Function
        End If

        ' Resize the sample array
        ReDim Sample(1 To Song.samples) As SampleType
        Dim As Unsigned Byte byte1, byte2

        ' Load the sample headers
        For i = 1 To Song.samples
            ' Read the sample name
            Get fileHandle, , Sample(i).sampleName

            ' Read sample length
            Get fileHandle, , byte1
            Get fileHandle, , byte2
            Sample(i).length = (byte1 * &H100 + byte2) * 2
            If Sample(i).length = 2 Then Sample(i).length = 0 ' Sanity check

            ' Read finetune
            Sample(i).c2SPD = GetC2SPD(Asc(Input$(1, fileHandle))) ' Convert finetune to c2spd

            ' Read volume
            Sample(i).volume = Asc(Input$(1, fileHandle))
            If Sample(i).volume > SAMPLE_VOLUME_MAX Then Sample(i).volume = SAMPLE_VOLUME_MAX ' Sanity check

            ' Read loop start
            Get fileHandle, , byte1
            Get fileHandle, , byte2
            Sample(i).loopStart = (byte1 * &H100 + byte2) * 2
            If Sample(i).loopStart >= Sample(i).length Then Sample(i).loopStart = 0 ' Sanity check

            ' Read loop length
            Get fileHandle, , byte1
            Get fileHandle, , byte2
            Sample(i).loopLength = (byte1 * &H100 + byte2) * 2
            If Sample(i).loopLength = 2 Then Sample(i).loopLength = 0 ' Sanity check

            ' Calculate repeat end
            Sample(i).loopEnd = Sample(i).loopStart + Sample(i).loopLength
            If Sample(i).loopEnd > Sample(i).length Then Sample(i).loopEnd = Sample(i).length ' Sanity check
        Next

        Song.orders = Asc(Input$(1, fileHandle))
        If Song.orders > ORDER_TABLE_MAX + 1 Then Song.orders = ORDER_TABLE_MAX + 1
        Song.endJumpOrder = Asc(Input$(1, fileHandle))
        If Song.endJumpOrder >= Song.orders Then Song.endJumpOrder = 0

        'Load the pattern table, and find the highest pattern to load.
        Song.highestPattern = 0
        For i = 0 To ORDER_TABLE_MAX
            Order(i) = Asc(Input$(1, fileHandle))
            If Order(i) > Song.highestPattern Then Song.highestPattern = Order(i)
        Next

        ' Resize pattern data array
        ReDim Pattern(0 To Song.highestPattern, 0 To PATTERN_ROW_MAX, 0 To Song.channels - 1) As NoteType
        Dim c As Unsigned Integer

        ' Skip past the 4 byte marker if this is a 31 sample mod
        If Song.samples = 31 Then Seek fileHandle, Loc(1) + 5

        ' Load the frequency table
        Restore PeriodTab
        Read c ' Read the size
        ReDim PeriodTable(0 To c - 1) As Unsigned Integer ' Allocate size elements
        ' Now read size values
        For i = 0 To c - 1
            Read PeriodTable(i)
        Next

        Dim As Unsigned Byte byte3, byte4
        Dim As Unsigned Integer a, b, period

        ' Load the patterns
        ' +-------------------------------------+
        ' | Byte 0    Byte 1   Byte 2   Byte 3  |
        ' +-------------------------------------+
        ' |aaaaBBBB CCCCCCCCC DDDDeeee FFFFFFFFF|
        ' +-------------------------------------+
        ' TODO: special handling for FLT8?
        For i = 0 To Song.highestPattern
            For a = 0 To PATTERN_ROW_MAX
                For b = 0 To Song.channels - 1
                    Get fileHandle, , byte1
                    Get fileHandle, , byte2
                    Get fileHandle, , byte3
                    Get fileHandle, , byte4

                    Pattern(i, a, b).sample = (byte1 And &HF0) Or SHR(byte3, 4)

                    period = SHL(byte1 And &HF, 8) Or byte2

                    ' Do the look up in the table against what is read in and store note
                    Pattern(i, a, b).note = NOTE_NONE
                    For c = 0 To 107
                        If period >= PeriodTable(c + 24) Then
                            Pattern(i, a, b).note = c
                            Exit For
                        End If
                    Next

                    Pattern(i, a, b).volume = NOTE_NO_VOLUME ' MODs don't have any volume field in the pattern
                    Pattern(i, a, b).effect = byte3 And &HF
                    Pattern(i, a, b).operand = byte4

                    ' Some sanity check
                    If Pattern(i, a, b).sample > Song.samples Then Pattern(i, a, b).sample = 0 ' Sample 0 means no sample. So valid sample are 1-15/31
                Next
            Next
        Next

        ' Resize the sample data array
        ReDim SampleData(1 To Song.samples) As String

        ' Load the samples
        For i = 1 To Song.samples
            ' Read and load sample size bytes of data. Also allocate 32 bytes more than needed for mixer runoff
            SampleData(i) = Input$(Sample(i).length, fileHandle) + String$(32, NULL)
        Next

        Close fileHandle

        LoadMODFile = TRUE
    End Function


    ' Initializes the audio mixer, prepares eveything else for playback and kick starts the timer and hence song playback
    Sub StartMODPlayer
        Dim As Unsigned Integer i, s

        ' Load the sine table
        Restore SineTab
        Read s
        ReDim SineTable(0 To s - 1) As Unsigned Byte
        For i = 0 To s - 1
            Read SineTable(i)
        Next

        ' Set the mix rate to match that of the system
        Song.mixerRate = SndRate

        ' Initialize some important stuff
        Song.orderPosition = 0
        Song.patternRow = 0
        Song.speed = SONG_SPEED_DEFAULT
        Song.tick = Song.speed
        Song.volume = SONG_VOLUME_MAX
        Song.isPaused = FALSE

        ' Setup the channel array
        ReDim Channel(0 To Song.channels - 1) As ChannelType

        ' Setup panning for all channels except last one if we have an odd number
        ' I hope I did this right. But I don't care even if it not the classic way. This is cooler :)
        For i = 0 To Song.channels - 1 - (Song.channels Mod 2)
            If i Mod 2 = 0 Then
                Channel(i).panningPosition = SAMPLE_PAN_LEFT + SAMPLE_PAN_CENTER / 2
            Else
                Channel(i).panningPosition = SAMPLE_PAN_RIGHT - SAMPLE_PAN_CENTER / 2
            End If
        Next
        ' Set the last channel to center. This also works for single channel
        If Song.channels Mod 2 = 1 Then
            Channel(Song.channels - 1).panningPosition = SAMPLE_PAN_CENTER
        End If

        ' Allocate a QB64 sound pipe
        Song.qb64SoundPipe = SndOpenRaw

        ' Feed some amount of silent samples to the QB64 sound pipe
        ' This helps reduce initial buffer underrun hiccups
        For i = 1 To BUFFER_UNDERRUN_PROTECTION * 60 ' since sample rate is per second
            SndRaw NULL, NULL, Song.qb64SoundPipe
        Next

        ' Allocate a QB64 Timer
        Song.qb64Timer = FreeTimer
        UpdateMODTimer SONG_BPM_DEFAULT
        Timer(Song.qb64Timer) On

        Song.isPlaying = TRUE
    End Sub


    ' Frees all allocated resources, stops the timer and hence song playback
    Sub StopMODPlayer
        ' Free QB64 timer
        Timer(Song.qb64Timer) Off
        Timer(Song.qb64Timer) Free

        SndRawDone Song.qb64SoundPipe ' Sumbit whatever is remaining in the raw buffer for playback
        SndClose Song.qb64SoundPipe ' Close QB64 sound pipe

        Song.isPlaying = FALSE
    End Sub


    ' Called by the QB64 timer at a specified rate
    Sub MODPlayerTimerHandler
        ' Check conditions for which we should just exit and not process anything
        If Song.orderPosition >= Song.orders Then Exit Sub

        ' Set the playing flag to true
        Song.isPlaying = TRUE

        ' If song is paused simply feed silence to the QB64 sound pipe and exit
        ' Again, this helps use avoid stuttering and hiccups when playback is resumed
        If Song.isPaused Then
            Dim i As Long

            For i = 1 To Song.mixerBufferSize
                SndRaw NULL, NULL, Song.qb64SoundPipe
            Next

            Exit Sub
        End If

        If Song.tick >= Song.speed Then
            ' Reset song tick
            Song.tick = 0

            ' Process pattern row if pattern delay is over
            If Song.patternDelay = 0 Then

                ' Save the pattern and row for UpdateMODTick()
                ' The pattern that we are playing is always Song.tickPattern
                Song.tickPattern = Order(Song.orderPosition)
                Song.tickPatternRow = Song.patternRow

                ' Process the row
                UpdateMODRow

                ' Increment the row counter
                ' Note UpdateMODTick() should pickup stuff using tickPattern & tickPatternRow
                ' This is because we are already at a new row not processed by UpdateMODRow()
                Song.patternRow = Song.patternRow + 1

                ' Check if we have finished the pattern and then move to the next one
                If Song.patternRow > PATTERN_ROW_MAX Then
                    Song.orderPosition = Song.orderPosition + 1
                    Song.patternRow = 0

                    ' Check if we need to loop or stop
                    If Song.orderPosition >= Song.orders Then
                        If Song.isLooping Then
                            Song.orderPosition = Song.endJumpOrder
                            Song.speed = SONG_SPEED_DEFAULT
                            Song.tick = Song.speed
                        Else
                            Song.isPlaying = FALSE
                        End If
                    End If
                End If
            Else
                Song.patternDelay = Song.patternDelay - 1
            End If
        Else
            UpdateMODTick
        End If

        ' Mix the current tick
        MixMODFrame

        ' Increment song tick on each update
        Song.tick = Song.tick + 1
    End Sub


    ' Updates a row of notes and play them out on tick 0
    Sub UpdateMODRow
        Dim As Unsigned Byte nChannel, nNote, nSample, nVolume, nEffect, nOperand, nOpX, nOpY
        Dim nPatternRow As Integer
        Dim As Bit jumpEffectFlag, breakEffectFlag ' This is set to true when a pattern jump effect and pattern break effect are triggered

        ' We need this so that we don't start accessing -1 elements in the pattern array when there is a pattern jump
        nPatternRow = Song.patternRow

        ' Process all channels
        For nChannel = 0 To Song.channels - 1
            nNote = Pattern(Song.tickPattern, nPatternRow, nChannel).note
            nSample = Pattern(Song.tickPattern, nPatternRow, nChannel).sample
            nVolume = Pattern(Song.tickPattern, nPatternRow, nChannel).volume
            nEffect = Pattern(Song.tickPattern, nPatternRow, nChannel).effect
            nOperand = Pattern(Song.tickPattern, nPatternRow, nChannel).operand
            nOpX = SHR(nOperand, 4)
            nOpY = nOperand And &HF

            ' Set volume. We never play if sample number is zero. Our sample array is 1 based
            ' ONLY RESET VOLUME IF THERE IS A SAMPLE NUMBER
            If nSample > 0 Then
                Channel(nChannel).sample = nSample
                ' Don't get the volume if delay note, set it when the delay note actually happens
                If Not (nEffect = &HE And nOpX = &HD) Then
                    Channel(nChannel).volume = Sample(nSample).volume
                End If
            End If

            If nNote < NOTE_NONE And Channel(nChannel).sample > 0 Then
                Channel(nChannel).period = 8363 * PeriodTable(nNote) / Sample(Channel(nChannel).sample).c2SPD
                Channel(nChannel).note = nNote

                ' Retrigger tremolo and vibrato waveforms
                If Channel(nChannel).waveControl And &HF < 4 Then Channel(nChannel).vibratoPosition = 0
                If SHR(Channel(nChannel).waveControl, 4) < 4 Then Channel(nChannel).tremoloPosition = 0

                ' ONLY RESET FREQUENCY IF THERE IS A NOTE VALUE AND PORTA NOT SET
                If nEffect <> &H3 And nEffect <> &H5 Then
                    Channel(nChannel).frequency = Channel(nChannel).period
                    Channel(nChannel).pitch = GetPitchFromPeriod(Channel(nChannel).frequency)
                    Channel(nChannel).samplePosition = 0
                    Channel(nChannel).isPlaying = TRUE
                End If
            End If

            If nVolume <= SAMPLE_VOLUME_MAX Then Channel(nChannel).volume = nVolume
            If nNote = NOTE_KEY_OFF Then Channel(nChannel).volume = 0

            ' Process tick 0 effects
            Select Case nEffect
                Case &H3 ' 3: Porta To Note
                    If nOperand > 0 Then Channel(nChannel).portamentoSpeed = nOperand
                    If nNote >= 0 Then Channel(nChannel).portamentoTo = Channel(nChannel).period

                Case &H5 ' 5: Tone Portamento + Volume Slide
                    If nNote >= 0 Then Channel(nChannel).portamentoTo = Channel(nChannel).period

                Case &H4 ' 4: Vibrato
                    If nOpX > 0 Then Channel(nChannel).vibratoSpeed = nOpX
                    If nOpY > 0 Then Channel(nChannel).vibratoDepth = nOpY

                Case &H7 ' 7: Tremolo
                    If nOpX > 0 Then Channel(nChannel).tremoloSpeed = nOpX
                    If nOpY > 0 Then Channel(nChannel).tremoloDepth = nOpY

                Case &H8 ' 8: Set Panning Position
                    ' Don't care about DMP panning BS. We are doing this Fasttracker style
                    Channel(nChannel).panningPosition = nOperand

                Case &H9 ' 9: Set Sample Offset
                    If nOperand > 0 Then Channel(nChannel).samplePosition = nOperand * 256

                Case &HB ' 11: Jump To Pattern
                    Song.orderPosition = nOperand
                    If Song.orderPosition >= Song.orders Then Song.orderPosition = Song.endJumpOrder
                    Song.patternRow = -1 ' This will increment right after & we will start at 0
                    jumpEffectFlag = TRUE

                Case &HC ' 12: Set Volume
                    Channel(nChannel).volume = nOperand ' Operand can never be -ve cause it is unsigned. So we only clip for max below
                    If Channel(nChannel).volume > SAMPLE_VOLUME_MAX Then Channel(nChannel).volume = SAMPLE_VOLUME_MAX

                Case &HD ' 13: Pattern Break
                    Song.patternRow = (nOpX * 10) + nOpY - 1
                    If Song.patternRow > PATTERN_ROW_MAX Then Song.patternRow = -1
                    If Not breakEffectFlag And Not jumpEffectFlag Then
                        Song.orderPosition = Song.orderPosition + 1
                        If Song.orderPosition >= Song.orders Then Song.orderPosition = Song.endJumpOrder
                    End If
                    breakEffectFlag = TRUE

                Case &HE ' 14: Extended Effects
                    Select Case nOpX
                        Case &H0 ' 0: Set Filter
                            Song.useHQMixer = nOpY <> 0

                        Case &H1 ' 1: Fine Portamento Up
                            Channel(nChannel).frequency = Channel(nChannel).frequency - nOpY * 4
                            Channel(nChannel).pitch = GetPitchFromPeriod(Channel(nChannel).frequency)

                        Case &H2 ' 2: Fine Portamento Down
                            Channel(nChannel).frequency = Channel(nChannel).frequency + nOpY * 4
                            Channel(nChannel).pitch = GetPitchFromPeriod(Channel(nChannel).frequency)

                        Case &H3 ' 3: Glissando Control
                            Title "Extended effect not implemented: " + Str$(nEffect) + "-" + Str$(nOpX)

                        Case &H4 ' 4: Set Vibrato Waveform
                            Channel(nChannel).waveControl = Channel(nChannel).waveControl And &HF0
                            Channel(nChannel).waveControl = Channel(nChannel).waveControl Or nOpY

                        Case &H5 ' 5: Set Finetune
                            Sample(Channel(nChannel).sample).c2SPD = GetC2SPD(nOpY)

                        Case &H6 ' 6: Pattern Loop
                            If nOpY = 0 Then
                                Channel(nChannel).patternLoopRow = nPatternRow
                            Else
                                If Channel(nChannel).patternLoopRowCounter = 0 Then
                                    Channel(nChannel).patternLoopRowCounter = nOpY
                                Else
                                    Channel(nChannel).patternLoopRowCounter = Channel(nChannel).patternLoopRowCounter - 1
                                End If
                                If Channel(nChannel).patternLoopRowCounter > 0 Then Song.patternRow = Channel(nChannel).patternLoopRow - 1
                            End If

                        Case &H7 ' 7: Set Tremolo WaveForm
                            Channel(nChannel).waveControl = Channel(nChannel).waveControl And &HF
                            Channel(nChannel).waveControl = Channel(nChannel).waveControl Or SHL(nOpY, 4)

                        Case &H8 ' 8: 16 position panning
                            If nOpY > 15 Then nOpY = 15
                            ' Why does this kind of stuff bother me so much. We just could have written "/ 17" XD
                            Channel(nChannel).panningPosition = nOpY * ((SAMPLE_PAN_RIGHT - SAMPLE_PAN_LEFT) / 15)

                        Case &HA ' 10: Fine Volume Slide Up
                            Channel(nChannel).volume = Channel(nChannel).volume + nOpY
                            If Channel(nChannel).volume > SAMPLE_VOLUME_MAX Then Channel(nChannel).volume = SAMPLE_VOLUME_MAX

                        Case &HB ' 11: Fine Volume Slide Down
                            Channel(nChannel).volume = Channel(nChannel).volume - nOpY
                            If Channel(nChannel).volume < 0 Then Channel(nChannel).volume = 0

                        Case &HD ' 13: Delay Note
                            Channel(nChannel).isPlaying = FALSE

                        Case &HE ' 14: Pattern Delay
                            Song.patternDelay = nOpY

                        Case &HF ' 15: Invert Loop
                            Title "Extended effect not implemented: " + Str$(nEffect) + "-" + Str$(nOpX)
                    End Select

                Case &HF ' 15: Set Speed
                    If nOperand < 32 Then
                        Song.speed = nOperand
                    Else
                        UpdateMODTimer nOperand
                    End If
            End Select
        Next
    End Sub


    ' Updates any tick based effects after tick 0
    Sub UpdateMODTick
        Dim As Unsigned Byte nChannel, nVolume, nEffect, nOperand, nOpX, nOpY

        ' Process all channels
        For nChannel = 0 To Song.channels - 1
            ' Only process if we have a period set
            If Not Channel(nChannel).frequency = 0 Then
                ' We are not processing a new row but tick 1+ effects
                ' So we pick these using tickPattern and tickPatternRow
                nVolume = Pattern(Song.tickPattern, Song.tickPatternRow, nChannel).volume
                nEffect = Pattern(Song.tickPattern, Song.tickPatternRow, nChannel).effect
                nOperand = Pattern(Song.tickPattern, Song.tickPatternRow, nChannel).operand
                nOpX = SHR(nOperand, 4)
                nOpY = nOperand And &HF

                Select Case nEffect
                    Case &H0 ' 0: Arpeggio
                        If (nOperand > 0) Then
                            Select Case Song.tick Mod 3 ' TODO: Check why this sounds wierd with 0, 1, 2
                                Case 2
                                    Channel(nChannel).pitch = GetPitchFromPeriod(Channel(nChannel).frequency)
                                Case 1
                                    Channel(nChannel).pitch = GetPitchFromPeriod(PeriodTable(Channel(nChannel).note + nOpX))
                                Case 0
                                    Channel(nChannel).pitch = GetPitchFromPeriod(PeriodTable(Channel(nChannel).note + nOpY))
                            End Select
                        End If

                    Case &H1 ' 1: Porta Up
                        Channel(nChannel).frequency = Channel(nChannel).frequency - nOperand * 4
                        Channel(nChannel).pitch = GetPitchFromPeriod(Channel(nChannel).frequency)
                        If Channel(nChannel).frequency < 56 Then Channel(nChannel).frequency = 56

                    Case &H2 ' 2: Porta Down
                        Channel(nChannel).frequency = Channel(nChannel).frequency + nOperand * 4
                        Channel(nChannel).pitch = GetPitchFromPeriod(Channel(nChannel).frequency)

                    Case &H3 ' 3: Porta To Note
                        DoPortamento nChannel

                    Case &H4 ' 4: Vibrato
                        DoVibrato nChannel

                    Case &H5 ' 5: Tone Portamento + Volume Slide
                        DoPortamento nChannel
                        DoVolumeSlide nChannel, nOpX, nOpY

                    Case &H6 ' 6: Vibrato + Volume Slide
                        DoVibrato nChannel
                        DoVolumeSlide nChannel, nOpX, nOpY

                    Case &H7 ' 7: Tremolo
                        DoTremolo nChannel

                    Case &HA ' 10: Volume Slide
                        DoVolumeSlide nChannel, nOpX, nOpY

                    Case &HE ' 14: Extended Effects
                        Select Case nOpX
                            Case &H9 ' 9: Retrigger Note
                                If nOpY <> 0 Then
                                    If Song.tick Mod nOpY = 0 Then
                                        Channel(nChannel).isPlaying = TRUE
                                        Channel(nChannel).samplePosition = 0
                                    End If
                                End If

                            Case &HC ' 12: Cut Note
                                If Song.tick = nOpY Then Channel(nChannel).volume = 0

                            Case &HD ' 13: Delay Note
                                If Song.tick = nOpY Then
                                    If Channel(nChannel).sample > 0 Then Channel(nChannel).volume = Sample(Channel(nChannel).sample).volume
                                    If nVolume <= SAMPLE_VOLUME_MAX Then Channel(nChannel).volume = nVolume
                                    Channel(nChannel).pitch = GetPitchFromPeriod(Channel(nChannel).frequency)
                                    Channel(nChannel).samplePosition = 0
                                    Channel(nChannel).isPlaying = TRUE
                                End If
                        End Select
                End Select
            End If
        Next
    End Sub


    ' Mixes and queues a frame/tick worth of samples
    ' All mixing calculations are done using floating-point math (it's 2022 :)
    Sub MixMODFrame
        Dim As Long c, i, nPos, nSample, nVolume
        Dim As Single fPan, fPos, fSam, fPitch
        Dim As Byte bSam1, bSam2
        Dim As Bit isLooping

        ' Allocate a temporary mixer buffer that will hold sample data for both channels
        ' This is conveniently zeroed by QB64, so that is nice. We don't have to do it
        ' Here 1 is the left channnel and 2 is the right channel
        Dim mixerBuffer(1 To 2, 1 To Song.mixerBufferSize) As Single

        ' We will iterate through each channel completely rather than jumping from channel to channel
        ' We are doing this because it is easier for the CPU to access adjacent memory rather than something far away
        ' Also because we do not have to fetch stuff from multiple arrays too many times
        For c = 0 To Song.channels - 1
            ' Get the sample number we need to work with
            nSample = Channel(c).sample

            ' Only proceed if we have a valid sample number (> 0)
            If Not nSample = 0 Then
                isLooping = (Sample(nSample).loopLength > 0)

                ' Proceed further if we have not completed or are looping
                If Channel(c).isPlaying Or isLooping Then
                    ' Get some values we need frequently during the mixing interation below
                    ' Note that these do not change at all during the mixing process
                    nVolume = Channel(c).volume
                    fPan = Channel(c).panningPosition
                    fPitch = Channel(c).pitch

                    ' Next we go through the channel sample data and mix it to our mixerBuffer
                    For i = 1 To Song.mixerBufferSize
                        ' We need these too many times
                        fPos = Channel(c).samplePosition

                        ' Check if we are looping
                        If isLooping Then
                            ' Reset loop position if we reached the end of the loop
                            If fPos >= Sample(nSample).loopEnd Then
                                fPos = Sample(nSample).loopStart
                            End If
                        Else
                            ' For non-looping sample simply set the isplayed flag as false if we reached the end
                            If fPos >= Sample(nSample).length Then
                                Channel(c).isPlaying = FALSE
                                ' The below two lines may not be required but are here for good measure to deal with problematic mods
                                Channel(c).samplePosition = 0
                                Channel(c).pitch = 0
                                ' Exit the for mixing loop as we have no more samples to mix for this channel
                                Exit For
                            End If
                        End If

                        ' We don't want anything below 0
                        If fPos < 0 Then fPos = 0

                        ' Samples are stored in a string and strings are 1 based
                        If Song.useHQMixer Then
                            ' Apply interpolation
                            nPos = Fix(fPos)
                            bSam1 = Asc(SampleData(nSample), 1 + nPos) ' This will convert the unsigned byte (the way it is stored) to signed byte
                            bSam2 = Asc(SampleData(nSample), 2 + nPos) ' This will convert the unsigned byte (the way it is stored) to signed byte
                            fSam = bSam1 + (bSam2 - bSam1) * (fPos - nPos)
                        Else
                            bSam1 = Asc(SampleData(nSample), 1 + fPos) ' This will convert the unsigned byte (the way it is stored) to signed byte
                            fSam = bSam1
                        End If

                        ' The following two lines does volume & panning
                        ' The below expressions were simplified and rearranged to reduce the number of divisions
                        mixerBuffer(1, i) = mixerBuffer(1, i) + (fSam * nVolume * (SAMPLE_PAN_RIGHT - fPan)) / (SAMPLE_PAN_RIGHT * SAMPLE_VOLUME_MAX)
                        mixerBuffer(2, i) = mixerBuffer(2, i) + (fSam * nVolume * fPan) / (SAMPLE_PAN_RIGHT * SAMPLE_VOLUME_MAX)

                        ' Move to the next sample position based on the pitch
                        Channel(c).samplePosition = fPos + fPitch
                    Next
                End If
            End If
        Next

        Dim As Single fsamLT, fsamRT
        ' Feed the samples to the QB64 sound pipe
        For i = 1 To Song.mixerBufferSize
            ' Apply global volume and scale sample to QB64 sound pipe specs
            fSam = Song.volume / (256 * SONG_VOLUME_MAX) ' TODO: 256? Is this right?
            fsamLT = mixerBuffer(1, i) * fSam
            fsamRT = mixerBuffer(2, i) * fSam

            ' Clip samples to QB64 range
            If fsamLT < -1 Then fsamLT = -1
            If fsamLT > 1 Then fsamLT = 1
            If fsamRT < -1 Then fsamRT = -1
            If fsamRT > 1 Then fsamRT = 1

            ' Feed the samples to the QB64 sound pipe
            SndRaw fsamLT, fsamRT, Song.qb64SoundPipe
        Next
    End Sub


    ' Carry out a tone portamento to a certain note
    Sub DoPortamento (chan As Unsigned Byte)
        If Channel(chan).frequency < Channel(chan).portamentoTo Then
            Channel(chan).frequency = Channel(chan).frequency + Channel(chan).portamentoSpeed * 4
            If Channel(chan).frequency > Channel(chan).portamentoTo Then Channel(chan).frequency = Channel(chan).portamentoTo
        ElseIf Channel(chan).frequency > Channel(chan).portamentoTo Then
            Channel(chan).frequency = Channel(chan).frequency - Channel(chan).portamentoSpeed * 4
            If Channel(chan).frequency < Channel(chan).portamentoTo Then Channel(chan).frequency = Channel(chan).portamentoTo
        End If

        Channel(chan).pitch = GetPitchFromPeriod(Channel(chan).frequency)
    End Sub


    ' Carry out a volume slide using +x -y
    Sub DoVolumeSlide (chan As Unsigned Byte, x As Unsigned Byte, y As Unsigned Byte)
        Channel(chan).volume = Channel(chan).volume + x - y
        If Channel(chan).volume < 0 Then Channel(chan).volume = 0
        If Channel(chan).volume > SAMPLE_VOLUME_MAX Then Channel(chan).volume = SAMPLE_VOLUME_MAX
    End Sub


    ' Carry out a vibrato at a certain depth and speed
    Sub DoVibrato (chan As Unsigned Byte)
        Dim delta As Unsigned Integer
        Dim temp As Unsigned Byte

        temp = Channel(chan).vibratoPosition And 31

        Select Case Channel(chan).waveControl And 3
            Case 0 ' Sine
                delta = SineTable(temp)

            Case 1 ' Saw down
                temp = SHL(temp, 3)
                If Channel(chan).vibratoPosition < 0 Then temp = 255 - temp
                delta = temp

            Case 2 ' Square
                delta = 255

            Case 3 ' TODO: Random?
                delta = SineTable(temp)
        End Select

        delta = SHR(delta * Channel(chan).vibratoDepth, 5) ' SHR 7 SHL 2

        If Channel(chan).vibratoPosition >= 0 Then
            Channel(chan).pitch = GetPitchFromPeriod(Channel(chan).frequency + delta)
        Else
            Channel(chan).pitch = GetPitchFromPeriod(Channel(chan).frequency - delta)
        End If

        Channel(chan).vibratoPosition = Channel(chan).vibratoPosition + Channel(chan).vibratoSpeed
        If Channel(chan).vibratoPosition > 31 Then Channel(chan).vibratoPosition = Channel(chan).vibratoPosition - 64
    End Sub


    ' Carry out a tremolo at a certain depth and speed
    Sub DoTremolo (chan As Unsigned Byte)
        Dim delta As Unsigned Integer
        Dim temp As Unsigned Byte

        temp = Channel(chan).tremoloPosition And 31

        Select Case SHR(Channel(chan).waveControl, 4) And 3
            Case 0 ' Sine
                delta = SineTable(temp)

            Case 1 ' Saw down
                temp = SHL(temp, 3)
                If Channel(chan).tremoloPosition < 0 Then temp = 255 - temp
                delta = temp

            Case 2 ' Square
                delta = 255

            Case 3 ' TODO: Random?
                delta = SineTable(temp)
        End Select

        delta = SHR(delta * Channel(chan).tremoloDepth, 6)

        If Channel(chan).tremoloPosition >= 0 Then
            If Channel(chan).volume + delta > SAMPLE_VOLUME_MAX Then delta = SAMPLE_VOLUME_MAX - Channel(chan).volume
            Channel(chan).volume = Channel(chan).volume + delta
        Else
            If Channel(chan).volume - delta < 0 Then delta = Channel(chan).volume
            Channel(chan).volume = Channel(chan).volume - delta
        End If

        Channel(chan).tremoloPosition = Channel(chan).tremoloPosition + Channel(chan).tremoloSpeed
        If Channel(chan).tremoloPosition > 31 Then Channel(chan).tremoloPosition = Channel(chan).tremoloPosition - 64
    End Sub


    ' This gives us the sample pitch based on the period for mixing
    Function GetPitchFromPeriod! (period As Unsigned Integer)
        GetPitchFromPeriod = AMIGA_CONSTANT / (period * Song.mixerRate)
    End Function


    ' Return C2 speed for a finetune
    Function GetC2SPD~% (ft As Unsigned Byte)
        Select Case ft
            Case 0
                GetC2SPD = 8363
            Case 1
                GetC2SPD = 8413
            Case 2
                GetC2SPD = 8463
            Case 3
                GetC2SPD = 8529
            Case 4
                GetC2SPD = 8581
            Case 5
                GetC2SPD = 8651
            Case 6
                GetC2SPD = 8723
            Case 7
                GetC2SPD = 8757
            Case 8
                GetC2SPD = 7895
            Case 9
                GetC2SPD = 7941
            Case 10
                GetC2SPD = 7985
            Case 11
                GetC2SPD = 8046
            Case 12
                GetC2SPD = 8107
            Case 13
                GetC2SPD = 8169
            Case 14
                GetC2SPD = 8232
            Case 15
                GetC2SPD = 8280
            Case Else
                GetC2SPD = 8363
        End Select
    End Function
    '-----------------------------------------------------------------------------------------------------
$End If
'---------------------------------------------------------------------------------------------------------

