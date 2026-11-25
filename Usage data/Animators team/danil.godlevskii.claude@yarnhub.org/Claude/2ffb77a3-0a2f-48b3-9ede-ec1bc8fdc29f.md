<!-- anim-team-librarian {"schema":1,"updatedAt":1793271045,"messages":7} -->
# Sequence 0253A\_E05\_S01\_C2 disappears on creation

Session ID: 2ffb77a3-0a2f-48b3-9ede-ec1bc8fdc29f

Created (UTC): 2026-10-29T10:47:19.443Z

Updated (UTC): 2026-10-29T10:50:45.79Z

## User (sent 2026-10-29T10:47:19.443Z)

    I have an issue with 0253A_E05_S01_C2 sequence, if i create it it instantly dissapears, but if i try to create it once more it prompts me that such sequence already exists

## Assistant (sent 2026-10-29T10:47:21.66Z)

    Using systematic-debugging to investigate this before proposing a fix.

## Assistant (sent 2026-10-29T10:47:25.172Z)

    Phase 1: the asset exists on disk, so "already exists" is accurate. The question is why it vanishes from the editor. I'll check the files, SVN status and the editor log.

## Assistant (sent 2026-10-29T10:48:11.326Z)

    C2 isn't really new. It already exists in SVN, and the SVN plugin removes whatever file you save over it.
    
    **What I found**
    - **SVN has a real C2.** `0253_Animatic_Episodes/0253A_E5/0253A_E05_S01_C2.uasset` is a 1.8 MB sequence, committed by polina.putilina in r1373. On your disk the file is missing, and `svn status` shows it as `!`.
    - **Your delete didn't go through.** At 10:23 today you deleted C2 in the editor. The editor ran `svn delete`, and SVN refused it with E195006 ("has local modifications"), so the file stayed registered in SVN.
    - **Creating it again triggers the vanishing.**
      - The editor saves the new file.
      - The plugin then runs `svn revert` on that path, which wipes the file you just saved.
      - It then tries `svn copy C1 → C2`, which fails with E155010 "not a directory".
      - The new asset is gone from disk, but the editor's asset registry still lists it. That is why the second attempt says it already exists, and why you got the "Overwrite Existing Object" prompt.
    - **A stray redirector sits at the new location.** `0253_AE01/0253A_E5/0253A_E05_S01_C2.uasset` is only 1613 bytes. It is an ObjectRedirector left over from moving the folder into `0253_AE01`, and it points at the old C2 path. SVN doesn't track it (`?`).
    
    The same state shows up in other files. C1 is modified (`M`). C3, C4 and `_UDS.umap` are `A +`, meaning copied and added locally. `0253_EP5.uasset` is added.
    
    **Fix I'd propose**
    1. Close the editor, so it stops re-saving over these files.
    2. Run `svn revert` on the old C2. This brings back the real 1.8 MB sequence and clears the "missing" state.
    3. Delete the unversioned redirector stubs in `0253_AE01/0253A_E5/`.
    4. Reopen the editor and check that C2 loads. If you want a different C2, delete the restored one through the editor (right-click → Delete) and commit that, then create the new one.
    
    I haven't run any of this. I haven't confirmed that step 2 brings C2 back, and I may be wrong about what the `svn revert` call does. I'd check `svn status` after each step.
    
    Is the existing C2 in SVN one you want to keep, or do you want a fresh sequence under that name?

## User (sent 2026-10-29T10:50:31.55Z)

    Restore C2

## Assistant (sent 2026-10-29T10:50:37.647Z)

    The editor isn't running, so I'll revert C2 and move the redirector stub into the scratchpad as a backup instead of deleting it.

## Assistant (sent 2026-10-29T10:50:45.79Z)

    C2 is back. The original sequence is restored at `0253_Animatic_Episodes/0253A_E5/0253A_E05_S01_C2.uasset`. It is the 1,826,415-byte file from r1373, and `svn status` shows it clean. I haven't opened it in the editor to confirm it loads.
    
    I moved the stray redirector stub out of `0253_AE01/0253A_E5/`. The backup is at `C:\Users\DANIL-GODLEVSKII\AppData\Local\Temp\claude\E--SVN-YH-Anim-58\2ffb77a3-0a2f-48b3-9ede-ec1bc8fdc29f\scratchpad\C2_redirector_AE01.uasset`.
    
    Four other unversioned files are still in `0253_AE01/0253A_E5/`: C1, `0253T_B17_Straight_Flight`, `0253T_ME262_Flight` and `0253_L_Cesium.umap`. They look like leftovers from the same folder move, but I only checked the C2 stub, so I left them alone. If any of them is also a redirector, you could hit the same "already exists" problem on that asset.
    
    If you want a fresh C2 instead of the restored one, delete it through the editor and commit the delete first. Then create the new one.
