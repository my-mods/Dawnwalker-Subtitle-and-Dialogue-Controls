-- LogLevels.lua
-- MIT License. Single source of truth for diagnostic verbosity.
--
-- Levels are cumulative: choosing a level prints that level's messages plus
-- everything more severe. Debug therefore prints everything, and Off prints
-- nothing at all.
--
--   Off      Print nothing. The deliberate "I know it is broken" choice.
--   Error    The mod gave up on something: it disabled itself or a feature.
--   Warning  One capability degraded; the rest of the mod still works.
--   Info     Notable lifecycle moments during normal play.
--   Debug    Everything, including per-event tracing and timing summaries.
--
-- Warning is the normal default. Debug alone enables detailed tracing and
-- diagnostic timings; explicit Off also suppresses failure reports.
local M = {}

M.OFF = 0
M.ERROR = 1
M.WARNING = 2
M.INFO = 3
M.DEBUG = 4

M.DEFAULT = M.WARNING

-- Ordered quietest to loudest. This is the order the settings picker lists.
M.ordered = {M.OFF, M.ERROR, M.WARNING, M.INFO, M.DEBUG}

-- Written into each log line so its severity is visible at a glance. Off has
-- no tag because nothing is ever printed at that level.
M.tags = {
    [M.ERROR] = 'ERROR',
    [M.WARNING] = 'WARN',
    [M.INFO] = 'INFO',
    [M.DEBUG] = 'DEBUG',
}

-- Shown in Mod Settings, in `M.ordered` order.
M.labels = {
    [M.OFF] = 'Off',
    [M.ERROR] = 'Error',
    [M.WARNING] = 'Warning',
    [M.INFO] = 'Info',
    [M.DEBUG] = 'Debug',
}

function M.valid(level)
    return M.tags[level] ~= nil or level == M.OFF
end

-- Translates the `debugLogging` on/off toggle that levels replaced.
--
-- On meant "print the tracing output too", so it becomes Debug. Off still
-- printed every failure and degradation notice, which is what Warning covers,
-- so Off becomes Warning rather than Off. Mapping it to Off instead would
-- silently take away diagnostics that players already rely on.
function M.fromLegacyToggle(enabled)
    return enabled == 1 and M.DEBUG or M.WARNING
end

return M
