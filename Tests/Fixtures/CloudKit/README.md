# Paired CloudKit control

`paired-verified.mp3` is a 3,965-byte copy of the existing public repository fixture `../PortableIdentity/rewrite-fixture.mp3`, tagged once through the signed Moonlight app during audit L03. It contains no private library audio. Its only intended change is the embedded Moonlight identity.

- Embedded UUID (both MP3 UFID and TXXX): `DF8D2FC5-69A5-4AE2-BAC3-325D70B351B8`
- SHA-256: `8e08d35df7ef86f5ea7b7a87b9212dc1e8a15b394c4dd619bba44db6a60889bb`
- Record name: `track_DF8D2FC5-69A5-4AE2-BAC3-325D70B351B8`

Copy this file to a disposable audit folder before importing. Do not import/edit the checked-in fixture directly. Both Macs must confirm its hash and UUID before P02. The original untagged fixture remains unchanged. This is test data, not an automatic identity reconciliation mechanism.

## Fresh remote-first control (P02-R2)

`paired-remote-first.mp3` is a separate copy of the same public untagged source, tagged and read-back verified through the signed app on September 7. It preserves the original P02 control and avoids retained physical-file history when testing a clean remote placeholder.

- Embedded UUID (both MP3 UFID and TXXX): `920AB46F-81CF-4D02-82E1-C52DD2132B5A`
- SHA-256: `1de075979efc8ea4b71b83209166896928b73e1ccf9209ea3144446db63068fb`
- Record name: `track_920AB46F-81CF-4D02-82E1-C52DD2132B5A`

Copy only after the coordinated remote-placeholder baseline has been observed. Do not import the checked-in path or retag either control. Acquiring the repository fixture alone is not an import.
