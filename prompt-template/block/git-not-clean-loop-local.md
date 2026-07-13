
**Special Case - .loop directory detected**:
The `.loop/` directory is created by loop:start-rlcr-loop and should NOT be committed.
Please add it to .gitignore:
```bash
echo '.loop*' >> .gitignore
git add .gitignore
```
