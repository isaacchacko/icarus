# Bug report {{id}}

{{reporter}} filed a report about isovim itself with `iso bug`. Turn it into one GitHub issue in
{{repo}}, then finish. The report, as filed, is {{file}}:

> {{text}}

Filed {{time}} on {{host}}, isovim {{sha}}, from {{scope}}.{{images}}

PRIVACY: {{repo}} is a PUBLIC repo. Reporters often work in private repos (customer names, SAP
data, prod queries, internal PR numbers, people's names). Write only what's about isovim itself:
no other repo's code, data, customer or people names, paths beyond ~/.iso/<owner>/<repo>-style
placeholders, PR or ticket numbers from other repos, tokens, or emails. When the reporter's text
needs that to make sense, paraphrase generically ("an agent in a private repo"). The raw report
stays local in ~/.isovim/bugs/ only. Never paste it, a screenshot, or a log line you haven't
checked against this rule.

1. Gather context, briefly:
   - the lines of ~/.isovim/errors.log near the report's time;
   - the TUI's messages, if it's open: `timeout 5 nvim --server {{socket}} --remote-expr "execute('messages')"`;
   - {{transcript}};
   - the code involved, from a quick read of this repo (file:line pointers to {{sha}}).
2. Decide what it is: a bug (isovim did something wrong), a complaint (it works as built, but gets
   in the way) or a request (something new). Create the label if it's missing:
   `gh label create <bug|complaint|request> --repo {{repo}}` (an error saying it exists is fine).
3. Check the open issues first (`gh issue list --repo {{repo}} --state open --search "<words>"`).
   If one already covers it, comment there with what this report adds instead of opening another.
   Otherwise open one with `gh issue create --repo {{repo}} --label <label>`: a clear title; what
   happened, in the reporter's words where they pass the privacy rule; the context you gathered;
   the code pointers; and the isovim sha.
4. Record the issue (or the comment's) URL: `iso __bug-done {{id}} <url>`. Then tell your parent in one
   line, with the URL, and stop. Don't change any code.
