using System;
using System.Diagnostics;
using System.Text;

namespace LivingWorld.Core;

// Thin process helpers. Two shapes are used:
//   * StartHidden - long-running children (DB engine, Java servers, brain). They
//     get their own hidden console window (matching Start-Process -WindowStyle
//     Hidden) and outlive the launcher, so nothing is redirected.
//   * Run - short foreground commands (the mysql client) whose stdout/stderr and
//     exit code we capture and log.
public static class Proc
{
    public static Process StartHidden(string exe, string arguments, string workingDir)
    {
        var psi = new ProcessStartInfo
        {
            FileName = exe,
            Arguments = arguments,
            WorkingDirectory = workingDir,
            UseShellExecute = true,
            WindowStyle = ProcessWindowStyle.Hidden,
        };
        var p = Process.Start(psi)
                ?? throw new LauncherException($"Failed to start: {exe}");
        return p;
    }

    public static Process StartVisible(string exe, string workingDir)
    {
        var psi = new ProcessStartInfo
        {
            FileName = exe,
            WorkingDirectory = workingDir,
            UseShellExecute = true,
        };
        return Process.Start(psi)
               ?? throw new LauncherException($"Failed to start: {exe}");
    }

    public sealed record Result(int ExitCode, string StdOut, string StdErr);

    // Run a command to completion, capturing output. Optional stdinText is fed to
    // the process's standard input (used to pipe a .sql file into the mysql client).
    public static Result Run(string exe, string[] args, string? workingDir = null, string? stdinText = null)
    {
        var psi = new ProcessStartInfo
        {
            FileName = exe,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = stdinText != null,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);
        if (!string.IsNullOrEmpty(workingDir)) psi.WorkingDirectory = workingDir;

        using var p = Process.Start(psi)
                      ?? throw new LauncherException($"Failed to start: {exe}");

        var stdout = new StringBuilder();
        var stderr = new StringBuilder();
        p.OutputDataReceived += (_, e) => { if (e.Data != null) stdout.AppendLine(e.Data); };
        p.ErrorDataReceived += (_, e) => { if (e.Data != null) stderr.AppendLine(e.Data); };
        p.BeginOutputReadLine();
        p.BeginErrorReadLine();

        if (stdinText != null)
        {
            p.StandardInput.Write(stdinText);
            p.StandardInput.Close();
        }

        p.WaitForExit();
        return new Result(p.ExitCode, stdout.ToString().Trim(), stderr.ToString().Trim());
    }
}
