#requires -Version 5.1
<#
.SYNOPSIS
	PowerTorrent - a dependency-free BitTorrent client for Windows PowerShell 5.1.

.DESCRIPTION
	A BitTorrent client in a single PowerShell 5.1 script. Torrents, magnets,
	trackers, DHT, encryption, uTP. Can seed when the download is done.

	No extra modules or binaries. Optional WireGuard and OpenVPN: import a
	config and torrent traffic only leaves as encrypted packets to the VPN.
	If the tunnel is down, nothing goes out.

	WPF window by default. Use -NoGui for the console.

.PARAMETER Torrent
	Path to a .torrent file, or a magnet:? URI. If omitted, the WPF window
	opens (unless -NoGui, which shows a file picker).

.PARAMETER Magnet
	A magnet:? URI.

.PARAMETER SavePath
	Directory that will contain the downloaded content. Defaults to the folder
	that holds the .torrent file, or the current directory for magnets.

.PARAMETER Port
	Listen port. Default 6881.

.PARAMETER MaxPeers
	Maximum peer connections per torrent. Default 80.

.PARAMETER Sequential
	Download pieces in order.

.PARAMETER NoDht
	Do not query the mainline DHT for extra peers.

.PARAMETER NoSeed
	Exit when the download completes instead of seeding.

.PARAMETER NoEncrypt
	No protocol encryption.

.PARAMETER NoUtp
	TCP only.

.PARAMETER Peer
	Connect to this peer first (ip:port).

.PARAMETER LogLevel
	0 = errors, 1 = info (default), 2 = detail, 3 = debug.

.PARAMETER ListOnly
	Parse the torrent, print metadata, and exit.

.PARAMETER SelfTest
	Run tests and exit.

.PARAMETER NoGui
	Use the console dashboard instead of the WPF window.

.PARAMETER Register
	Register PowerTorrent as the current-user handler for magnet: links
	(and .torrent files unless -MagnetOnly). Then exit.

.PARAMETER Unregister
	Remove the current-user magnet: / .torrent associations. Then exit.

.PARAMETER MagnetOnly
	With -Register, associate magnet: links only (not .torrent files).

.PARAMETER Accept
	Skip the legal notice this run.

.PARAMETER RememberAccept
	Skip the legal notice and remember that.

.EXAMPLE
	.\PowerTorrent.ps1 -Torrent .\ubuntu.torrent -SavePath D:\Downloads

.EXAMPLE
	.\PowerTorrent.ps1 -Magnet 'magnet:?xt=urn:btih:...' -SavePath D:\Downloads

.EXAMPLE
	.\PowerTorrent.ps1 -SelfTest

.EXAMPLE
	.\PowerTorrent.ps1 -Register

.EXAMPLE
	.\PowerTorrent.ps1 -Accept

.EXAMPLE
	.\PowerTorrent.ps1 -RememberAccept

.NOTES
	Settings live in PowerTorrent.ini next to the script. An imported VPN
	config is PowerTorrent.vpn.conf, same folder.
#>
[CmdletBinding()]
param(
	[Parameter(Position = 0)]
	[Alias('Path')]
	[string]$Torrent,

	[Alias('Uri')]
	[string]$Magnet = '',

	[Alias('OutputDirectory', 'Out')]
	[string]$SavePath = '',

	[int]$Port = 6881,

	[int]$MaxPeers = 80,

	[switch]$Sequential,

	[switch]$NoDht,

	[switch]$NoSeed,

	[switch]$NoEncrypt,

	[switch]$NoUtp,

	[string]$Peer = '',

	[ValidateSet(0, 1, 2, 3)]
	[int]$LogLevel = 1,

	[switch]$ListOnly,

	[switch]$SelfTest,

	[switch]$NoGui,

	[switch]$Register,

	[switch]$Unregister,

	[switch]$MagnetOnly,

	[switch]$Accept,

	[switch]$RememberAccept
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSBoundParameters.ContainsKey('Verbose') -and $VerbosePreference -eq 'Continue') {
	$LogLevel = 3
}

# Helpers
$script:PowerTorrentCSharp = @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Numerics;
using System.Security.Cryptography;
using System.ComponentModel;
using System.Text;
using System.Threading;
using System.Net.Security;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;

namespace PowerTorrent {

	public sealed class EngineSettings {
		public string TorrentPath;
		public string MagnetUri;
		public string SavePath;
		public int ListenPort;
		public int MaxPeers;
		public int LogLevel;
		public bool Sequential;
		public bool EnableDht;
		public bool SeedAfterComplete;
		public string ForcedPeer;
		public bool EnableEncrypt;
		public bool EnableUtp;
	}

	public sealed class TorrentRow : INotifyPropertyChanged {
		public event PropertyChangedEventHandler PropertyChanged;
		void Notify(string n) {
			PropertyChangedEventHandler h = PropertyChanged;
			if (h != null) h(this, new PropertyChangedEventArgs(n));
		}
		public string Id;
		string name = "";
		string sizeText = "";
		string progressText = "0%";
		string status = "Idle";
		string peersText = "0 / 0";
		string seedsText = "0";
		string downText = "0 B/s";
		string upText = "0 B/s";
		string eta = "--";
		string hash = "";
		string ratioText = "--";
		string availText = "--";
		string remainingText = "--";
		string downTotalText = "0 B";
		string upTotalText = "0 B";
		string piecesText = "0 / 0";
		double progress;
		public string Name { get { return name; } set { if (name != value) { name = value; Notify("Name"); } } }
		public string SizeText { get { return sizeText; } set { if (sizeText != value) { sizeText = value; Notify("SizeText"); } } }
		public double Progress { get { return progress; } set { if (progress != value) { progress = value; Notify("Progress"); } } }
		public string ProgressText { get { return progressText; } set { if (progressText != value) { progressText = value; Notify("ProgressText"); } } }
		public string Status { get { return status; } set { if (status != value) { status = value; Notify("Status"); } } }
		public string PeersText { get { return peersText; } set { if (peersText != value) { peersText = value; Notify("PeersText"); } } }
		public string SeedsText { get { return seedsText; } set { if (seedsText != value) { seedsText = value; Notify("SeedsText"); } } }
		public string DownText { get { return downText; } set { if (downText != value) { downText = value; Notify("DownText"); } } }
		public string UpText { get { return upText; } set { if (upText != value) { upText = value; Notify("UpText"); } } }
		public string Eta { get { return eta; } set { if (eta != value) { eta = value; Notify("Eta"); } } }
		public string Hash { get { return hash; } set { if (hash != value) { hash = value; Notify("Hash"); } } }
		public string RatioText { get { return ratioText; } set { if (ratioText != value) { ratioText = value; Notify("RatioText"); } } }
		public string AvailText { get { return availText; } set { if (availText != value) { availText = value; Notify("AvailText"); } } }
		public string RemainingText { get { return remainingText; } set { if (remainingText != value) { remainingText = value; Notify("RemainingText"); } } }
		public string DownTotalText { get { return downTotalText; } set { if (downTotalText != value) { downTotalText = value; Notify("DownTotalText"); } } }
		public string UpTotalText { get { return upTotalText; } set { if (upTotalText != value) { upTotalText = value; Notify("UpTotalText"); } } }
		public string PiecesText { get { return piecesText; } set { if (piecesText != value) { piecesText = value; Notify("PiecesText"); } } }
		public void Apply(EngineStatus s) {
			if (s == null) return;
			Name = s.Name;
			Hash = s.InfoHashHex;
			SizeText = Engine.Fmt(s.TotalSize);
			Progress = s.ProgressPercent;
			ProgressText = s.ProgressPercent.ToString("0.0", CultureInfo.InvariantCulture) + "%";
			Status = s.State;
			PeersText = s.PeersConnected.ToString(CultureInfo.InvariantCulture) + " / " + s.PeersKnown.ToString(CultureInfo.InvariantCulture);
			SeedsText = s.SeedsConnected.ToString(CultureInfo.InvariantCulture) + " / " + s.SeedsKnown.ToString(CultureInfo.InvariantCulture);
			DownText = Engine.Fmt((long)s.DownBytesPerSec) + "/s";
			UpText = Engine.Fmt((long)s.UpBytesPerSec) + "/s";
			Eta = s.Eta;
			DownTotalText = Engine.Fmt(s.Downloaded);
			UpTotalText = Engine.Fmt(s.Uploaded);
			PiecesText = s.PiecesDone.ToString(CultureInfo.InvariantCulture) + " / " + s.PiecesTotal.ToString(CultureInfo.InvariantCulture);
			long rem = s.TotalSize - s.Downloaded;
			if (rem < 0) rem = 0;
			RemainingText = Engine.Fmt(rem);
			if (s.Downloaded > 0)
				RatioText = ((double)s.Uploaded / (double)s.Downloaded).ToString("0.000", CultureInfo.InvariantCulture);
			else if (s.Uploaded > 0)
				RatioText = "\u221E";
			else
				RatioText = "--";
			if (s.Availability > 0)
				AvailText = s.Availability.ToString("0.0", CultureInfo.InvariantCulture);
			else
				AvailText = "--";
		}
	}

	public static class TorrentRowFilter {
		public static string Name = "All";
		public static bool Pass(object obj) {
			TorrentRow row = obj as TorrentRow;
			if (row == null) return true;
			string st = row.Status;
			if (st == null) st = "";
			string n = Name;
			if (n == null || n.Length == 0 || n == "All") return true;
			if (n == "Downloading") return st == "Downloading" || st == "Metadata" || st == "Announcing";
			if (n == "Seeding") return st == "Seeding";
			if (n == "Completed") return st == "Complete" || st == "Seeding";
			if (n == "Paused") return st == "Paused";
			if (n == "Checking") return st == "Hashing";
			return true;
		}
		public static Predicate<object> GetPredicate() {
			return Pass;
		}
	}

	public sealed class MagnetLink {
		public byte[] InfoHash;
		public string InfoHashHex = "";
		public byte[] V2Hash;
		public string V2InfoHashHex = "";
		public bool V2Only;
		public string DisplayName = "";
		public List<string> Trackers = new List<string>();
		public List<string> Webseeds = new List<string>();

		public static MagnetLink Parse(string uri) {
			if (string.IsNullOrEmpty(uri)) throw new ArgumentException("empty magnet");
			string u = uri.Trim();
			if (u.Length < 8 || u.Substring(0, 8).ToLowerInvariant() != "magnet:?")
				throw new Exception("not a magnet URI");
			MagnetLink mag = new MagnetLink();
			string query = u.Substring(8);
			string[] parts = query.Split('&');
			for (int i = 0; i < parts.Length; i++) {
				string kv = parts[i];
				int eq = kv.IndexOf('=');
				if (eq <= 0) continue;
				string key = Unesc(kv.Substring(0, eq)).ToLowerInvariant();
				string val = Unesc(kv.Substring(eq + 1));
				if (key == "xt" || key.StartsWith("xt.")) {
					string low = val.ToLowerInvariant();
					if (low.StartsWith("urn:btih:")) {
						string h = val.Substring(9).Trim();
						byte[] hash = ParseInfoHash(h);
						if (hash != null) {
							mag.InfoHash = hash;
							mag.InfoHashHex = BitConverter.ToString(hash).Replace("-", "").ToLowerInvariant();
						}
					} else if (low.StartsWith("urn:btmh:")) {
						string h = val.Substring(9).Trim().ToLowerInvariant();
						if (h.StartsWith("1220")) h = h.Substring(4);
						if (h.Length == 64) {
							try {
								byte[] v2 = new byte[32];
								for (int n = 0; n < 32; n++) v2[n] = Convert.ToByte(h.Substring(n * 2, 2), 16);
								mag.V2Hash = v2;
								mag.V2InfoHashHex = h;
								if (mag.InfoHash == null) {
									mag.InfoHash = new byte[20];
									Buffer.BlockCopy(v2, 0, mag.InfoHash, 0, 20);
									mag.InfoHashHex = BitConverter.ToString(mag.InfoHash).Replace("-", "").ToLowerInvariant();
									mag.V2Only = true;
								}
							} catch { }
						}
					}
				} else if (key == "dn" && mag.DisplayName.Length == 0) {
					mag.DisplayName = val;
				} else if (key == "tr") {
					if (!string.IsNullOrEmpty(val)) mag.Trackers.Add(val.Trim());
				} else if (key == "ws") {
					if (!string.IsNullOrEmpty(val)) mag.Webseeds.Add(val.Trim());
				}
			}
			if (mag.InfoHash == null || mag.InfoHash.Length != 20)
				throw new Exception("magnet missing xt=urn:btih or xt=urn:btmh info hash");
			return mag;
		}

		static string Unesc(string s) {
			try { return Uri.UnescapeDataString(s.Replace('+', ' ')); }
			catch { return s; }
		}

		public static byte[] ParseInfoHash(string h) {
			if (string.IsNullOrEmpty(h)) return null;
			h = h.Trim();
			if (h.Length == 40) {
				try {
					byte[] b = new byte[20];
					for (int i = 0; i < 20; i++) b[i] = Convert.ToByte(h.Substring(i * 2, 2), 16);
					return b;
				} catch { return null; }
			}
			if (h.Length == 32) return FromBase32(h);
			return null;
		}

		public static byte[] FromBase32(string s) {
			const string abc = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
			s = s.ToUpperInvariant().Replace("=", "");
			int buffer = 0, bits = 0, idx = 0;
			byte[] outb = new byte[20];
			for (int i = 0; i < s.Length; i++) {
				int v = abc.IndexOf(s[i]);
				if (v < 0) return null;
				buffer = (buffer << 5) | v;
				bits += 5;
				if (bits >= 8) {
					bits -= 8;
					if (idx >= 20) return null;
					outb[idx++] = (byte)((buffer >> bits) & 0xFF);
				}
			}
			if (idx != 20) return null;
			return outb;
		}
	}

	public sealed class EngineStatus {
		public string Name = "";
		public string InfoHashHex = "";
		public string State = "Idle";
		public string ErrorMessage = "";
		public long Downloaded;
		public long Uploaded;
		public long TotalSize;
		public double ProgressPercent;
		public double DownBytesPerSec;
		public double UpBytesPerSec;
		public int PeersConnected;
		public int PeersKnown;
		public int PiecesDone;
		public int PiecesTotal;
		public int ListenPort;
		public int SeedsConnected;
		public int SeedsKnown;
		public double Availability;
		public string Eta = "--";
		public string[] LogLines = new string[0];
	}

	public sealed class TorrentInfo {
		public string Name = "";
		public string Comment = "";
		public string CreatedBy = "";
		public string InfoHashHex = "";
		public long TotalSize;
		public int PieceLength;
		public int PieceCount;
		public int FileCount;
		public string[] Trackers = new string[0];
		public string[] Webseeds = new string[0];
		public string[] Files = new string[0];
		public FileRow[] FileRows = new FileRow[0];
		public bool IsMulti;
		public string SavePath = "";
	}

	public sealed class FileRow : INotifyPropertyChanged {
		public event PropertyChangedEventHandler PropertyChanged;
		void Notify(string n) {
			PropertyChangedEventHandler h = PropertyChanged;
			if (h != null) h(this, new PropertyChangedEventArgs(n));
		}
		string name = "";
		string sizeText = "";
		string progressText = "0%";
		double progress;
		public string Name { get { return name; } set { if (name != value) { name = value; Notify("Name"); } } }
		public string SizeText { get { return sizeText; } set { if (sizeText != value) { sizeText = value; Notify("SizeText"); } } }
		public double Progress { get { return progress; } set { if (progress != value) { progress = value; Notify("Progress"); } } }
		public string ProgressText { get { return progressText; } set { if (progressText != value) { progressText = value; Notify("ProgressText"); } } }
		public FileRow() { }
	}

	internal static class Bt {
		public static void W32(byte[] b, int o, int v) {
			b[o] = (byte)((v >> 24) & 0xFF);
			b[o + 1] = (byte)((v >> 16) & 0xFF);
			b[o + 2] = (byte)((v >> 8) & 0xFF);
			b[o + 3] = (byte)(v & 0xFF);
		}
		public static int R32(byte[] b, int o) {
			return (int)(((uint)b[o] << 24) | ((uint)b[o + 1] << 16) | ((uint)b[o + 2] << 8) | (uint)b[o + 3]);
		}
		public static void W64(byte[] b, int o, long v) {
			ulong u = (ulong)v;
			b[o] = (byte)(u >> 56);
			b[o + 1] = (byte)(u >> 48);
			b[o + 2] = (byte)(u >> 40);
			b[o + 3] = (byte)(u >> 32);
			b[o + 4] = (byte)(u >> 24);
			b[o + 5] = (byte)(u >> 16);
			b[o + 6] = (byte)(u >> 8);
			b[o + 7] = (byte)u;
		}
		public static long R64(byte[] b, int o) {
			uint hi = (uint)R32(b, o);
			uint lo = (uint)R32(b, o + 4);
			return (long)(((ulong)hi << 32) | (ulong)lo);
		}
		public static string UrlEnc(byte[] data) {
			char[] hex = "0123456789ABCDEF".ToCharArray();
			StringBuilder sb = new StringBuilder(data.Length * 3);
			for (int i = 0; i < data.Length; i++) {
				sb.Append('%');
				sb.Append(hex[(data[i] >> 4) & 0xF]);
				sb.Append(hex[data[i] & 0xF]);
			}
			return sb.ToString();
		}
		public static string SafeName(string n) {
			if (string.IsNullOrEmpty(n)) return "unknown";
			n = n.Replace('/', '_').Replace('\\', '_');
			char[] bad = Path.GetInvalidFileNameChars();
			StringBuilder sb = new StringBuilder(n.Length);
			for (int i = 0; i < n.Length; i++) {
				char c = n[i];
				bool ok = true;
				for (int j = 0; j < bad.Length; j++) {
					if (c == bad[j]) { ok = false; break; }
				}
				sb.Append(ok ? c : '_');
			}
			string s = sb.ToString().Trim();
			if (s.Length == 0 || s == "." || s == "..") return "_";
			return s;
		}
		public static void AddCompactPeers(byte[] data, List<string> dst) {
			if (data == null) return;
			int n = data.Length / 6;
			for (int i = 0; i < n; i++) {
				int o = i * 6;
				int port = (data[o + 4] << 8) | data[o + 5];
				byte b0 = data[o];
				if (port <= 0 || port > 65535) continue;
				if (b0 == 0 || b0 == 127 || b0 == 255) continue;
				dst.Add(string.Format(CultureInfo.InvariantCulture, "{0}.{1}.{2}.{3}:{4}", data[o], data[o + 1], data[o + 2], data[o + 3], port));
			}
		}
		public static IPAddress ResolveV4(string host) {
			try {
				IPAddress parsed;
				if (IPAddress.TryParse(host, out parsed)) {
					if (parsed.AddressFamily == AddressFamily.InterNetwork) return parsed;
					return null;
				}
				if (VpnHub.HasConfig) {
					if (!VpnHub.TunnelOn) return null;
					return VpnHub.Resolve(host);
				}
				IPAddress[] addrs = Dns.GetHostAddresses(host);
				for (int i = 0; i < addrs.Length; i++) {
					if (addrs[i].AddressFamily == AddressFamily.InterNetwork) return addrs[i];
				}
			} catch {
			}
			return null;
		}
		public static byte[] MakePeerId() {
			byte[] id = new byte[20];
			byte[] prefix = Encoding.ASCII.GetBytes("-PT1200-");
			Buffer.BlockCopy(prefix, 0, id, 0, 8);
			RNGCryptoServiceProvider rng = new RNGCryptoServiceProvider();
			byte[] r = new byte[12];
			rng.GetBytes(r);
			rng.Dispose();
			string alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
			for (int i = 0; i < 12; i++) id[8 + i] = (byte)alphabet[r[i] % alphabet.Length];
			return id;
		}
	}

	internal sealed class Be {
		public int Kind;
		public long I;
		public byte[] Bytes;
		public List<Be> List;
		public Dictionary<string, Be> Dict;
		public List<KeyValuePair<byte[], Be>> Pairs;
		public static Be Int(long n) { Be b = new Be(); b.Kind = 0; b.I = n; return b; }
		public static Be Blob(byte[] x) { Be b = new Be(); b.Kind = 1; b.Bytes = x; return b; }
		public static Be FromList(List<Be> x) { Be b = new Be(); b.Kind = 2; b.List = x; return b; }
		public static Be FromDict(Dictionary<string, Be> x) { Be b = new Be(); b.Kind = 3; b.Dict = x; return b; }
		public Be Get(string key) {
			if (Dict == null) return null;
			Be v;
			if (Dict.TryGetValue(key, out v)) return v;
			return null;
		}
		public string Str(string key) {
			Be v = Get(key);
			if (v == null || v.Bytes == null) return null;
			return Encoding.UTF8.GetString(v.Bytes);
		}
		public long GetInt(string key, long def) {
			Be v = Get(key);
			if (v == null || v.Kind != 0) return def;
			return v.I;
		}
	}

	internal sealed class Benc {
		byte[] d;
		int i;
		int depth;
		Benc(byte[] data) { d = data; i = 0; depth = 0; }

		public static Be Decode(byte[] data) {
			int n;
			return DecodeAt(data, 0, out n);
		}

		public static Be DecodeAt(byte[] data, int offset, out int consumed) {
			consumed = 0;
			if (data == null || offset < 0 || offset >= data.Length) throw new Exception("empty bencode");
			Benc p = new Benc(data);
			p.i = offset;
			Be v = p.Parse();
			consumed = p.i - offset;
			return v;
		}

		public static byte[] SliceDictValue(byte[] data, string key) {
			if (data == null || data.Length == 0 || data[0] != (byte)'d') return null;
			Benc p = new Benc(data);
			p.i = 1;
			while (p.i < p.d.Length && p.d[p.i] != (byte)'e') {
				Be k = p.Parse();
				int vs = p.i;
				p.Parse();
				int ve = p.i;
				if (k.Bytes != null && Encoding.UTF8.GetString(k.Bytes) == key) {
					byte[] sl = new byte[ve - vs];
					Buffer.BlockCopy(p.d, vs, sl, 0, sl.Length);
					return sl;
				}
			}
			return null;
		}

		public static byte[] Encode(Be v) {
			MemoryStream ms = new MemoryStream();
			Enc(v, ms);
			return ms.ToArray();
		}

		static void Enc(Be v, MemoryStream ms) {
			if (v.Kind == 0) {
				byte[] t = Encoding.ASCII.GetBytes("i" + v.I.ToString(CultureInfo.InvariantCulture) + "e");
				ms.Write(t, 0, t.Length);
			} else if (v.Kind == 1) {
				byte[] t = Encoding.ASCII.GetBytes(v.Bytes.Length.ToString(CultureInfo.InvariantCulture) + ":");
				ms.Write(t, 0, t.Length);
				ms.Write(v.Bytes, 0, v.Bytes.Length);
			} else if (v.Kind == 2) {
				ms.WriteByte((byte)'l');
				for (int n = 0; n < v.List.Count; n++) Enc(v.List[n], ms);
				ms.WriteByte((byte)'e');
			} else {
				ms.WriteByte((byte)'d');
				List<string> keys = new List<string>(v.Dict.Keys);
				keys.Sort(StringComparer.Ordinal);
				for (int n = 0; n < keys.Count; n++) {
					Enc(Be.Blob(Encoding.UTF8.GetBytes(keys[n])), ms);
					Enc(v.Dict[keys[n]], ms);
				}
				ms.WriteByte((byte)'e');
			}
		}

		Be Parse() {
			if (depth > 64) throw new Exception("bencode too nested");
			if (i >= d.Length) throw new Exception("truncated bencode");
			byte c = d[i];
			if (c == (byte)'i') return ParseInt();
			if (c == (byte)'l') return ParseList();
			if (c == (byte)'d') return ParseDict();
			if (c >= (byte)'0' && c <= (byte)'9') return ParseBytes();
			throw new Exception("invalid bencode at " + i.ToString(CultureInfo.InvariantCulture));
		}

		Be ParseInt() {
			i++;
			int s = i;
			if (i < d.Length && d[i] == (byte)'-') i++;
			if (i >= d.Length || d[i] < (byte)'0' || d[i] > (byte)'9') throw new Exception("bad int");
			while (i < d.Length && d[i] != (byte)'e') {
				if (d[i] < (byte)'0' || d[i] > (byte)'9') throw new Exception("bad int");
				i++;
			}
			if (i >= d.Length) throw new Exception("unterminated int");
			string ns = Encoding.ASCII.GetString(d, s, i - s);
			i++;
			return Be.Int(long.Parse(ns, CultureInfo.InvariantCulture));
		}

		Be ParseBytes() {
			int s = i;
			while (i < d.Length && d[i] != (byte)':') i++;
			if (i >= d.Length) throw new Exception("bad string");
			int len = int.Parse(Encoding.ASCII.GetString(d, s, i - s), CultureInfo.InvariantCulture);
			i++;
			if (len < 0 || i + len > d.Length) throw new Exception("string overflow");
			byte[] b = new byte[len];
			Buffer.BlockCopy(d, i, b, 0, len);
			i += len;
			return Be.Blob(b);
		}

		Be ParseList() {
			depth++;
			i++;
			List<Be> list = new List<Be>();
			while (i < d.Length && d[i] != (byte)'e') list.Add(Parse());
			if (i >= d.Length) throw new Exception("unterminated list");
			i++;
			depth--;
			return Be.FromList(list);
		}

		Be ParseDict() {
			depth++;
			i++;
			Dictionary<string, Be> dict = new Dictionary<string, Be>();
			List<KeyValuePair<byte[], Be>> pairs = new List<KeyValuePair<byte[], Be>>();
			while (i < d.Length && d[i] != (byte)'e') {
				Be k = Parse();
				Be v = Parse();
				if (k.Bytes == null) throw new Exception("dict key is not a string");
				dict[Encoding.UTF8.GetString(k.Bytes)] = v;
				pairs.Add(new KeyValuePair<byte[], Be>(k.Bytes, v));
			}
			if (i >= d.Length) throw new Exception("unterminated dict");
			i++;
			depth--;
			Be b = Be.FromDict(dict);
			b.Pairs = pairs;
			return b;
		}
	}

	internal sealed class Rc4 {
		byte[] s = new byte[256];
		int i, j;
		public Rc4(byte[] key) {
			for (int k = 0; k < 256; k++) s[k] = (byte)k;
			int jj = 0;
			for (int k = 0; k < 256; k++) {
				jj = (jj + s[k] + key[k % key.Length]) & 255;
				byte t = s[k]; s[k] = s[jj]; s[jj] = t;
			}
			i = 0; j = 0;
		}
		Rc4() { }
		public Rc4 Clone() {
			Rc4 c = new Rc4();
			c.s = (byte[])s.Clone();
			c.i = i; c.j = j;
			return c;
		}
		public void Crypt(byte[] buf, int off, int n) {
			for (int k = 0; k < n; k++) {
				i = (i + 1) & 255;
				j = (j + s[i]) & 255;
				byte t = s[i]; s[i] = s[j]; s[j] = t;
				buf[off + k] ^= s[(s[i] + s[j]) & 255];
			}
		}
		public void Discard(int n) {
			byte[] t = new byte[n];
			Crypt(t, 0, n);
		}
	}

	internal static class Crypto {
		static readonly BigInteger DhP = BigInteger.Parse("00FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A63A36210000000000090563", NumberStyles.AllowHexSpecifier);
		static readonly BigInteger DhG = new BigInteger(2);

		public static byte[] Sha1(params byte[][] parts) {
			int len = 0;
			for (int i = 0; i < parts.Length; i++) len += parts[i].Length;
			byte[] all = new byte[len];
			int o = 0;
			for (int i = 0; i < parts.Length; i++) { Buffer.BlockCopy(parts[i], 0, all, o, parts[i].Length); o += parts[i].Length; }
			using (SHA1CryptoServiceProvider sha = new SHA1CryptoServiceProvider()) return sha.ComputeHash(all);
		}
		public static byte[] Sha256(byte[] d, int off, int len) {
			using (SHA256CryptoServiceProvider sha = new SHA256CryptoServiceProvider()) return sha.ComputeHash(d, off, len);
		}
		public static byte[] Sha256All(byte[] d) { return Sha256(d, 0, d.Length); }

		public static BigInteger RandomX() {
			byte[] r = new byte[21];
			RNGCryptoServiceProvider rng = new RNGCryptoServiceProvider();
			rng.GetBytes(r);
			rng.Dispose();
			r[20] = 0;
			r[0] |= 1;
			return new BigInteger(r);
		}
		public static byte[] Int96(BigInteger v) {
			byte[] le = v.ToByteArray();
			byte[] be = new byte[96];
			int n = le.Length;
			if (n > 0 && le[n - 1] == 0) n--;
			for (int i = 0; i < n && i < 96; i++) be[95 - i] = le[i];
			return be;
		}
		public static BigInteger From96(byte[] be) {
			byte[] le = new byte[97];
			for (int i = 0; i < 96; i++) le[i] = be[95 - i];
			return new BigInteger(le);
		}
		public static byte[] DhPub(BigInteger x) { return Int96(BigInteger.ModPow(DhG, x, DhP)); }
		public static byte[] DhSecret(byte[] their96, BigInteger x) {
			return Int96(BigInteger.ModPow(From96(their96), x, DhP));
		}
		public static Rc4 Rc4Key(bool initiatorSend, byte[] S, byte[] skey) {
			byte[] tag = Encoding.ASCII.GetBytes(initiatorSend ? "keyA" : "keyB");
			Rc4 r = new Rc4(Sha1(tag, S, skey));
			r.Discard(1024);
			return r;
		}
		public static byte[] MerklePiece(byte[] piece, int len) {
			List<byte[]> nodes = new List<byte[]>();
			int i = 0;
			while (i < len) {
				int n = Math.Min(16384, len - i);
				nodes.Add(Sha256(piece, i, n));
				i += n;
			}
			if (nodes.Count == 0) nodes.Add(Sha256(new byte[0], 0, 0));
			while (nodes.Count > 1) {
				List<byte[]> next = new List<byte[]>();
				for (int k = 0; k < nodes.Count; k += 2) {
					byte[] cat = new byte[64];
					Buffer.BlockCopy(nodes[k], 0, cat, 0, 32);
					if (k + 1 < nodes.Count) Buffer.BlockCopy(nodes[k + 1], 0, cat, 32, 32);
					next.Add(Sha256(cat, 0, 64));
				}
				nodes = next;
			}
			return nodes[0];
		}
		public static byte[] MerkleRoot(List<byte[]> layers) {
			if (layers == null || layers.Count == 0) return Sha256(new byte[0], 0, 0);
			List<byte[]> nodes = new List<byte[]>(layers);
			while (nodes.Count > 1) {
				List<byte[]> next = new List<byte[]>();
				for (int k = 0; k < nodes.Count; k += 2) {
					byte[] cat = new byte[64];
					Buffer.BlockCopy(nodes[k], 0, cat, 0, 32);
					if (k + 1 < nodes.Count) Buffer.BlockCopy(nodes[k + 1], 0, cat, 32, 32);
					next.Add(Sha256(cat, 0, 64));
				}
				nodes = next;
			}
			return nodes[0];
		}
	}

	internal abstract class PeerIo {
		public string Transport = "TCP";
		public abstract bool ReadExact(byte[] buf, int off, int n, int timeoutMs);
		public abstract void Write(byte[] buf, int n);
		public abstract bool PollRead(int microSeconds);
		public abstract int Available { get; }
		public abstract void Close();
	}

	internal sealed class TcpPeerIo : PeerIo {
		TcpClient tcp;
		Stream st;
		VpnTcp vt;
		Rc4 sendRc4, recvRc4;
		byte[] push = new byte[0];
		int pushOff;
		public TcpPeerIo(TcpClient c) {
			tcp = c;
			tcp.NoDelay = true;
			try { tcp.ReceiveBufferSize = 512 * 1024; } catch { }
			try { tcp.SendBufferSize = 256 * 1024; } catch { }
			st = c.GetStream();
			Transport = "TCP";
		}
		public TcpPeerIo(VpnTcp v) {
			vt = v;
			st = new VpnTcpStream(v);
			Transport = "TCP/WG";
		}
		public static TcpPeerIo Dial(string host, int port, int timeoutMs) {
			if (VpnHub.HasConfig) {
				if (!VpnHub.TunnelOn) return null;
				VpnTcp v = VpnHub.ConnectTcp(host, port, timeoutMs);
				if (v == null) return null;
				return new TcpPeerIo(v);
			}
			TcpClient c = new TcpClient();
			c.NoDelay = true;
			c.ReceiveBufferSize = 512 * 1024;
			c.SendBufferSize = 256 * 1024;
			IAsyncResult ar = c.BeginConnect(host, port, null, null);
			if (!ar.AsyncWaitHandle.WaitOne(timeoutMs, false)) {
				try { c.Close(); } catch { }
				return null;
			}
			try { c.EndConnect(ar); } catch { try { c.Close(); } catch { } return null; }
			return new TcpPeerIo(c);
		}
		void PushFront(byte[] d, int off, int n) {
			byte[] nb = new byte[n + (push.Length - pushOff)];
			Buffer.BlockCopy(d, off, nb, 0, n);
			if (push.Length - pushOff > 0) Buffer.BlockCopy(push, pushOff, nb, n, push.Length - pushOff);
			push = nb; pushOff = 0;
		}
		bool ReadRaw(byte[] buf, int off, int n, int timeoutMs) {
			int got = 0;
			while (got < n && pushOff < push.Length) buf[off + got++] = push[pushOff++];
			if (pushOff >= push.Length) { push = new byte[0]; pushOff = 0; }
			if (vt != null) {
				while (got < n) {
					int r = vt.Read(buf, off + got, n - got, timeoutMs);
					if (r <= 0) return false;
					got += r;
				}
				return true;
			}
			if (tcp != null) tcp.ReceiveTimeout = timeoutMs;
			while (got < n) {
				int r;
				try { r = st.Read(buf, off + got, n - got); }
				catch { return false; }
				if (r <= 0) return false;
				got += r;
			}
			return true;
		}
		public override bool ReadExact(byte[] buf, int off, int n, int timeoutMs) {
			if (!ReadRaw(buf, off, n, timeoutMs)) return false;
			if (recvRc4 != null) recvRc4.Crypt(buf, off, n);
			return true;
		}
		public override void Write(byte[] buf, int n) {
			byte[] outb = buf;
			if (sendRc4 != null) {
				outb = new byte[n];
				Buffer.BlockCopy(buf, 0, outb, 0, n);
				sendRc4.Crypt(outb, 0, n);
			}
			if (vt != null) vt.Write(outb, 0, n);
			else st.Write(outb, 0, n);
		}
		public override bool PollRead(int microSeconds) {
			try {
				if (pushOff < push.Length) return true;
				if (vt != null) return vt.Poll(microSeconds);
				NetworkStream ns = st as NetworkStream;
				if (ns != null && ns.DataAvailable) return true;
				return tcp.Client.Poll(microSeconds, SelectMode.SelectRead);
			} catch { return false; }
		}
		public override int Available {
			get {
				int a = push.Length - pushOff;
				if (vt != null) return a + vt.Available;
				try { a += tcp.Client.Available; } catch { }
				return a;
			}
		}
		public override void Close() {
			try { if (st != null) st.Close(); } catch { }
			try { if (vt != null) vt.Close(); } catch { }
			try { if (tcp != null) tcp.Close(); } catch { }
		}
		bool SockReady() {
			if (vt != null) return vt.Available > 0;
			try { return tcp != null && tcp.Client.Available > 0; } catch { return false; }
		}

		public bool TryMseOutgoing(byte[] skey) {
			try {
				BigInteger x = Crypto.RandomX();
				byte[] ya = Crypto.DhPub(x);
				RNGCryptoServiceProvider rng = new RNGCryptoServiceProvider();
				byte[] pad = new byte[24];
				rng.GetBytes(pad);
				rng.Dispose();
				byte[] pkt = new byte[96 + pad.Length];
				Buffer.BlockCopy(ya, 0, pkt, 0, 96);
				Buffer.BlockCopy(pad, 0, pkt, 96, pad.Length);
				st.Write(pkt, 0, pkt.Length);

				byte[] yb = new byte[96];
				if (!ReadRaw(yb, 0, 96, 5000)) return false;
				byte[] S = Crypto.DhSecret(yb, x);
				sendRc4 = Crypto.Rc4Key(true, S, skey);
				recvRc4 = Crypto.Rc4Key(false, S, skey);

				byte[] req1 = Crypto.Sha1(Encoding.ASCII.GetBytes("req1"), S);
				byte[] xor = Crypto.Sha1(Encoding.ASCII.GetBytes("req2"), skey);
				byte[] r3 = Crypto.Sha1(Encoding.ASCII.GetBytes("req3"), S);
				for (int i = 0; i < 20; i++) xor[i] ^= r3[i];
				byte[] vc = new byte[8];
				byte[] provide = new byte[4]; provide[3] = 0x03;
				byte[] padCLen = new byte[2];
				byte[] iaLen = new byte[2];
				byte[] encPart = new byte[8 + 4 + 2 + 2];
				Buffer.BlockCopy(vc, 0, encPart, 0, 8);
				Buffer.BlockCopy(provide, 0, encPart, 8, 4);
				sendRc4.Crypt(encPart, 0, encPart.Length);
				byte[] p3 = new byte[40 + encPart.Length];
				Buffer.BlockCopy(req1, 0, p3, 0, 20);
				Buffer.BlockCopy(xor, 0, p3, 20, 20);
				Buffer.BlockCopy(encPart, 0, p3, 40, encPart.Length);
				st.Write(p3, 0, p3.Length);

				byte[] rest = new byte[528];
				if (tcp != null) tcp.ReceiveTimeout = 5000;
				int got = 0;
				DateTime dead = DateTime.UtcNow.AddMilliseconds(5000);
				while (got < 8 && DateTime.UtcNow < dead) {
					if (!SockReady()) { Thread.Sleep(20); continue; }
					int r = st.Read(rest, got, rest.Length - got);
					if (r <= 0) break;
					got += r;
				}
				if (got < 8) return false;
				byte[] want = new byte[8];
				Rc4 probe = recvRc4.Clone();
				probe.Crypt(want, 0, 8);
				int start = -1;
				for (int s = 0; s <= got - 8; s++) {
					bool match = true;
					for (int k = 0; k < 8; k++) if (rest[s + k] != want[k]) { match = false; break; }
					if (match) { start = s; break; }
				}
				if (start < 0) return false;
				int left = got - start;
				byte[] p4 = new byte[Math.Max(left, 16)];
				Buffer.BlockCopy(rest, start, p4, 0, left);
				int need = 8 + 4 + 2;
				while (left < need) {
					int r = st.Read(p4, left, p4.Length - left);
					if (r <= 0) return false;
					left += r;
				}
				recvRc4.Crypt(p4, 0, 8);
				for (int k = 0; k < 8; k++) if (p4[k] != 0) return false;
				recvRc4.Crypt(p4, 8, 4);
				int sel = (p4[8] << 24) | (p4[9] << 16) | (p4[10] << 8) | p4[11];
				recvRc4.Crypt(p4, 12, 2);
				int padD = (p4[12] << 8) | p4[13];
				if (padD < 0 || padD > 512) return false;
				int have = left - 14;
				if (have < padD) {
					Array.Resize(ref p4, 14 + padD);
					if (!ReadRaw(p4, left, padD - have, 4000)) return false;
					left = 14 + padD;
				}
				if (padD > 0) recvRc4.Crypt(p4, 14, padD);
				int extra = left - (14 + padD);
				if (extra > 0) PushFront(p4, 14 + padD, extra);
				if ((sel & 2) == 0) { sendRc4 = null; recvRc4 = null; }
				Transport = "TCP/MSE";
				return true;
			} catch { return false; }
		}

		public void Unread(byte[] d, int off, int n) { PushFront(d, off, n); }

		public bool AcceptRouted(bool allowMse, out Engine matched) {
			matched = null;
			byte[] first = new byte[20];
			if (!ReadRaw(first, 0, 20, 8000)) return false;
			if (first[0] == 19 && Encoding.ASCII.GetString(first, 1, 19) == "BitTorrent protocol") {
				byte[] hs = new byte[68];
				Buffer.BlockCopy(first, 0, hs, 0, 20);
				if (!ReadRaw(hs, 20, 48, 8000)) return false;
				byte[] ih = new byte[20];
				Buffer.BlockCopy(hs, 28, ih, 0, 20);
				matched = Session.FindByHash(ih);
				PushFront(hs, 0, 68);
				return matched != null;
			}
			if (!allowMse) return false;
			PushFront(first, 0, 20);
			return AcceptMseRouted(out matched);
		}

		bool AcceptMseRouted(out Engine matched) {
			matched = null;
			try {
				byte[] ya = new byte[96];
				if (!ReadRaw(ya, 0, 96, 5000)) return false;
				BigInteger x = Crypto.RandomX();
				byte[] yb = Crypto.DhPub(x);
				RNGCryptoServiceProvider rng = new RNGCryptoServiceProvider();
				byte[] pad = new byte[24];
				rng.GetBytes(pad);
				rng.Dispose();
				byte[] pkt = new byte[96 + pad.Length];
				Buffer.BlockCopy(yb, 0, pkt, 0, 96);
				Buffer.BlockCopy(pad, 0, pkt, 96, pad.Length);
				st.Write(pkt, 0, pkt.Length);
				byte[] S = Crypto.DhSecret(ya, x);
				byte[] req1 = Crypto.Sha1(Encoding.ASCII.GetBytes("req1"), S);
				byte[] acc = new byte[640];
				int got = 0;
				DateTime dead = DateTime.UtcNow.AddMilliseconds(6000);
				int hit = -1;
				while (DateTime.UtcNow < dead && hit < 0) {
					if (SockReady()) {
						int r = st.Read(acc, got, acc.Length - got);
						if (r <= 0) break;
						got += r;
					} else Thread.Sleep(15);
					for (int s = 0; s <= got - 20; s++) {
						bool m = true;
						for (int k = 0; k < 20; k++) if (acc[s + k] != req1[k]) { m = false; break; }
						if (m) { hit = s; break; }
					}
				}
				if (hit < 0) return false;
				int pos = hit + 20;
				while (got < pos + 20) {
					int r = st.Read(acc, got, acc.Length - got);
					if (r <= 0) return false;
					got += r;
				}
				byte[] rec = new byte[20];
				Buffer.BlockCopy(acc, pos, rec, 0, 20);
				byte[] r3 = Crypto.Sha1(Encoding.ASCII.GetBytes("req3"), S);
				for (int i = 0; i < 20; i++) rec[i] ^= r3[i];
				byte[][] keys = Session.AllInfoHashes();
				byte[] skey = null;
				for (int ki = 0; ki < keys.Length; ki++) {
					byte[] expect = Crypto.Sha1(Encoding.ASCII.GetBytes("req2"), keys[ki]);
					bool ok = true;
					for (int i = 0; i < 20; i++) if (rec[i] != expect[i]) { ok = false; break; }
					if (ok) { skey = keys[ki]; break; }
				}
				if (skey == null) return false;
				matched = Session.FindByHash(skey);
				if (matched == null) return false;
				pos += 20;
				sendRc4 = Crypto.Rc4Key(false, S, skey);
				recvRc4 = Crypto.Rc4Key(true, S, skey);
				int need = pos + 8 + 4 + 2;
				while (got < need) {
					int r = st.Read(acc, got, acc.Length - got);
					if (r <= 0) return false;
					got += r;
				}
				recvRc4.Crypt(acc, pos, 8);
				for (int k = 0; k < 8; k++) if (acc[pos + k] != 0) return false;
				pos += 8;
				recvRc4.Crypt(acc, pos, 4);
				int provide = (acc[pos] << 24) | (acc[pos + 1] << 16) | (acc[pos + 2] << 8) | acc[pos + 3];
				pos += 4;
				recvRc4.Crypt(acc, pos, 2);
				int padC = (acc[pos] << 8) | (acc[pos + 1] & 0xFF);
				pos += 2;
				if (padC < 0 || padC > 512) return false;
				while (got < pos + padC + 2) {
					int r = st.Read(acc, got, acc.Length - got);
					if (r <= 0) return false;
					got += r;
				}
				if (padC > 0) { recvRc4.Crypt(acc, pos, padC); pos += padC; }
				recvRc4.Crypt(acc, pos, 2);
				int ia = (acc[pos] << 8) | (acc[pos + 1] & 0xFF);
				pos += 2;
				while (got < pos + ia) {
					Array.Resize(ref acc, Math.Max(acc.Length * 2, pos + ia));
					int r = st.Read(acc, got, acc.Length - got);
					if (r <= 0) return false;
					got += r;
				}
				if (ia > 0) { recvRc4.Crypt(acc, pos, ia); PushFront(acc, pos, ia); pos += ia; }
				if (got > pos) PushFront(acc, pos, got - pos);
				byte[] p4 = new byte[14];
				int sel = ((provide & 2) != 0) ? 2 : 1;
				p4[11] = (byte)sel;
				sendRc4.Crypt(p4, 0, 8);
				sendRc4.Crypt(p4, 8, 4);
				sendRc4.Crypt(p4, 12, 2);
				st.Write(p4, 0, 14);
				if (sel != 2) { sendRc4 = null; recvRc4 = null; Transport = "TCP"; }
				else Transport = "TCP/MSE";
				return true;
			} catch { matched = null; return false; }
		}

		public bool AcceptMseOrPlain(byte[] skey, bool allowMse) {
			byte[] first = new byte[20];
			if (!ReadRaw(first, 0, 20, 8000)) return false;
			if (first[0] == 19 && Encoding.ASCII.GetString(first, 1, 19) == "BitTorrent protocol") {
				PushFront(first, 0, 20);
				Transport = "TCP";
				return true;
			}
			if (!allowMse) return false;
			PushFront(first, 0, 20);
			try {
				byte[] ya = new byte[96];
				if (!ReadRaw(ya, 0, 96, 5000)) return false;
				BigInteger x = Crypto.RandomX();
				byte[] yb = Crypto.DhPub(x);
				RNGCryptoServiceProvider rng = new RNGCryptoServiceProvider();
				byte[] pad = new byte[24];
				rng.GetBytes(pad);
				rng.Dispose();
				byte[] pkt = new byte[96 + pad.Length];
				Buffer.BlockCopy(yb, 0, pkt, 0, 96);
				Buffer.BlockCopy(pad, 0, pkt, 96, pad.Length);
				st.Write(pkt, 0, pkt.Length);
				byte[] S = Crypto.DhSecret(ya, x);
				byte[] req1 = Crypto.Sha1(Encoding.ASCII.GetBytes("req1"), S);
				byte[] acc = new byte[640];
				int got = 0;
				DateTime dead = DateTime.UtcNow.AddMilliseconds(6000);
				int hit = -1;
				while (DateTime.UtcNow < dead && hit < 0) {
					if (SockReady()) {
						int r = st.Read(acc, got, acc.Length - got);
						if (r <= 0) break;
						got += r;
					} else Thread.Sleep(15);
					for (int s = 0; s <= got - 20; s++) {
						bool m = true;
						for (int k = 0; k < 20; k++) if (acc[s + k] != req1[k]) { m = false; break; }
						if (m) { hit = s; break; }
					}
				}
				if (hit < 0) return false;
				int pos = hit + 20;
				while (got < pos + 20) {
					int r = st.Read(acc, got, acc.Length - got);
					if (r <= 0) return false;
					got += r;
				}
				byte[] rec = new byte[20];
				Buffer.BlockCopy(acc, pos, rec, 0, 20);
				byte[] r3 = Crypto.Sha1(Encoding.ASCII.GetBytes("req3"), S);
				for (int i = 0; i < 20; i++) rec[i] ^= r3[i];
				byte[] expect = Crypto.Sha1(Encoding.ASCII.GetBytes("req2"), skey);
				for (int i = 0; i < 20; i++) if (rec[i] != expect[i]) return false;
				pos += 20;
				sendRc4 = Crypto.Rc4Key(false, S, skey);
				recvRc4 = Crypto.Rc4Key(true, S, skey);
				int need = pos + 8 + 4 + 2;
				while (got < need) {
					int r = st.Read(acc, got, acc.Length - got);
					if (r <= 0) return false;
					got += r;
				}
				recvRc4.Crypt(acc, pos, 8);
				for (int k = 0; k < 8; k++) if (acc[pos + k] != 0) return false;
				pos += 8;
				recvRc4.Crypt(acc, pos, 4);
				int provide = (acc[pos] << 24) | (acc[pos + 1] << 16) | (acc[pos + 2] << 8) | acc[pos + 3];
				pos += 4;
				recvRc4.Crypt(acc, pos, 2);
				int padC = (acc[pos] << 8) | acc[pos + 1];
				pos += 2;
				if (padC < 0 || padC > 512) return false;
				while (got < pos + padC + 2) {
					int r = st.Read(acc, got, acc.Length - got);
					if (r <= 0) return false;
					got += r;
				}
				if (padC > 0) { recvRc4.Crypt(acc, pos, padC); pos += padC; }
				recvRc4.Crypt(acc, pos, 2);
				int ia = (acc[pos] << 8) | acc[pos + 1];
				pos += 2;
				while (got < pos + ia) {
					Array.Resize(ref acc, Math.Max(acc.Length * 2, pos + ia));
					int r = st.Read(acc, got, acc.Length - got);
					if (r <= 0) return false;
					got += r;
				}
				if (ia > 0) { recvRc4.Crypt(acc, pos, ia); PushFront(acc, pos, ia); pos += ia; }
				if (got > pos) PushFront(acc, pos, got - pos);
				byte[] p4 = new byte[14];
				int sel = ((provide & 2) != 0) ? 2 : 1;
				p4[11] = (byte)sel;
				sendRc4.Crypt(p4, 0, 8);
				sendRc4.Crypt(p4, 8, 4);
				sendRc4.Crypt(p4, 12, 2);
				st.Write(p4, 0, 14);
				if (sel != 2) { sendRc4 = null; recvRc4 = null; Transport = "TCP"; }
				else Transport = "TCP/MSE";
				return true;
			} catch { return false; }
		}
	}

	internal sealed class UtpConn {
		public IPEndPoint Remote;
		public int SendId, RecvId;
		public int State; // 0 idle 1 syn 2 connected 3 closed
		UtpHub hub;
		ushort seq, ack;
		int nextIn;
		int remoteWnd = 64 * 1024;
		readonly object gate = new object();
		readonly Queue<byte> appIn = new Queue<byte>();
		readonly AutoResetEvent ev = new AutoResetEvent(false);
		readonly List<byte[]> inflight = new List<byte[]>();
		readonly List<ushort> infSeq = new List<ushort>();
		readonly List<DateTime> infSent = new List<DateTime>();
		readonly Dictionary<int, byte[]> reorder = new Dictionary<int, byte[]>();
		DateTime lastRecv = DateTime.UtcNow;
		const int Mss = 1200;

		public UtpConn(UtpHub hub) { this.hub = hub; }

		public bool Connect(string host, int port, int timeoutMs) {
			IPAddress ip = Bt.ResolveV4(host);
			if (ip == null) return false;
			Remote = new IPEndPoint(ip, port);
			Random rng = new Random(Guid.NewGuid().GetHashCode());
			RecvId = rng.Next(1, 60000);
			SendId = RecvId + 1;
			seq = (ushort)rng.Next(1, 60000);
			ack = 0;
			nextIn = -1;
			State = 1;
			hub.Register(this);
			SendPkt(4, RecvId, seq, ack, null);
			seq++;
			DateTime dead = DateTime.UtcNow.AddMilliseconds(timeoutMs);
			while (DateTime.UtcNow < dead && State != 2 && State != 3) {
				ev.WaitOne(50);
			}
			return State == 2;
		}

		public void AcceptSyn(ushort synSeq) {
			Random rng = new Random(Guid.NewGuid().GetHashCode());
			seq = (ushort)rng.Next(1, 60000);
			ack = synSeq;
			nextIn = synSeq + 1;
			State = 2;
			SendPkt(2, SendId, seq, ack, null);
		}

		public void OnPacket(byte[] pkt) {
			if (pkt == null || pkt.Length < 20) return;
			int type = (pkt[0] >> 4) & 0xF;
			int ext = pkt[1];
			int hdr = 20;
			while (ext != 0 && hdr + 2 <= pkt.Length) {
				ext = pkt[hdr];
				int elen = pkt[hdr + 1];
				hdr += 2 + elen;
				if (hdr > pkt.Length) return;
			}
			ushort theirSeq = (ushort)((pkt[16] << 8) | pkt[17]);
			ushort theirAck = (ushort)((pkt[18] << 8) | pkt[19]);
			remoteWnd = (pkt[12] << 24) | (pkt[13] << 16) | (pkt[14] << 8) | pkt[15];
			lastRecv = DateTime.UtcNow;
			lock (gate) {
				for (int i = inflight.Count - 1; i >= 0; i--) {
					if ((short)(theirAck - infSeq[i]) >= 0) {
						inflight.RemoveAt(i); infSeq.RemoveAt(i); infSent.RemoveAt(i);
					}
				}
				if (type == 4) { // SYN incoming
					ack = theirSeq;
					nextIn = theirSeq + 1;
					State = 2;
					SendPkt(2, SendId, seq, ack, null);
					ev.Set();
					return;
				}
				if (State == 1 && type == 2) {
					ack = theirSeq;
					nextIn = theirSeq + 1;
					State = 2;
					ev.Set();
					return;
				}
				if (type == 3) { State = 3; ev.Set(); return; }
				if (type == 1) {
					ack = theirSeq;
					State = 3;
					SendPkt(2, SendId, seq, ack, null);
					ev.Set();
					return;
				}
				if (type == 0 && pkt.Length > hdr) {
					int pay = pkt.Length - hdr;
					byte[] data = new byte[pay];
					Buffer.BlockCopy(pkt, hdr, data, 0, pay);
					if (nextIn < 0) nextIn = theirSeq;
					if (theirSeq == (ushort)nextIn) {
						for (int i = 0; i < data.Length; i++) appIn.Enqueue(data[i]);
						nextIn = (nextIn + 1) & 0xFFFF;
						ack = theirSeq;
						while (reorder.ContainsKey(nextIn)) {
							byte[] more = reorder[nextIn];
							reorder.Remove(nextIn);
							for (int i = 0; i < more.Length; i++) appIn.Enqueue(more[i]);
							ack = (ushort)nextIn;
							nextIn = (nextIn + 1) & 0xFFFF;
						}
						ev.Set();
					} else if ((short)(theirSeq - (ushort)nextIn) > 0 && reorder.Count < 64) {
						reorder[theirSeq] = data;
					}
					SendPkt(2, SendId, seq, ack, null);
				}
			}
		}

		public void SendPkt(int type, int connId, ushort sq, ushort ak, byte[] payload) {
			int plen = payload == null ? 0 : payload.Length;
			byte[] pkt = new byte[20 + plen];
			pkt[0] = (byte)((type << 4) | 1);
			pkt[1] = 0;
			pkt[2] = (byte)((connId >> 8) & 0xFF);
			pkt[3] = (byte)(connId & 0xFF);
			uint ts = (uint)(Environment.TickCount * 1000);
			pkt[4] = (byte)(ts >> 24); pkt[5] = (byte)(ts >> 16); pkt[6] = (byte)(ts >> 8); pkt[7] = (byte)ts;
			pkt[12] = 0; pkt[13] = 0x40; pkt[14] = 0; pkt[15] = 0;
			pkt[16] = (byte)(sq >> 8); pkt[17] = (byte)sq;
			pkt[18] = (byte)(ak >> 8); pkt[19] = (byte)ak;
			if (plen > 0) Buffer.BlockCopy(payload, 0, pkt, 20, plen);
			hub.SendRaw(pkt, Remote);
		}

		public void Tick() {
			lock (gate) {
				DateTime now = DateTime.UtcNow;
				if (State == 3) return;
				if ((now - lastRecv).TotalSeconds > 30) { State = 3; ev.Set(); return; }
				for (int i = 0; i < inflight.Count; i++) {
					if ((now - infSent[i]).TotalMilliseconds > 600 && infSeq.Count > 0) {
						hub.SendRaw(inflight[i], Remote);
						infSent[i] = now;
					}
				}
			}
		}

		public bool ReadExact(byte[] buf, int off, int n, int timeoutMs) {
			DateTime dead = DateTime.UtcNow.AddMilliseconds(timeoutMs);
			int got = 0;
			while (got < n) {
				Tick();
				lock (gate) {
					while (appIn.Count > 0 && got < n) buf[off + got++] = appIn.Dequeue();
					if (State == 3 && got < n && appIn.Count == 0) return false;
				}
				if (got >= n) return true;
				int left = (int)(dead - DateTime.UtcNow).TotalMilliseconds;
				if (left <= 0) return false;
				ev.WaitOne(Math.Min(200, left));
			}
			return true;
		}

		public void Write(byte[] buf, int n) {
			int o = 0;
			while (o < n && State == 2) {
				Tick();
				lock (gate) {
					if (inflight.Count >= 128) { }
					else {
						int take = Math.Min(Mss, n - o);
						byte[] pay = new byte[take];
						Buffer.BlockCopy(buf, o, pay, 0, take);
						byte[] pkt = new byte[20 + take];
						int connId = SendId;
						ushort sq = seq;
						seq++;
						pkt[0] = (byte)((0 << 4) | 1);
						pkt[2] = (byte)((connId >> 8) & 0xFF);
						pkt[3] = (byte)(connId & 0xFF);
						uint ts = (uint)(Environment.TickCount * 1000);
						pkt[4] = (byte)(ts >> 24); pkt[5] = (byte)(ts >> 16); pkt[6] = (byte)(ts >> 8); pkt[7] = (byte)ts;
						pkt[13] = 0x40;
						pkt[16] = (byte)(sq >> 8); pkt[17] = (byte)sq;
						pkt[18] = (byte)(ack >> 8); pkt[19] = (byte)ack;
						Buffer.BlockCopy(pay, 0, pkt, 20, take);
						inflight.Add(pkt); infSeq.Add(sq); infSent.Add(DateTime.UtcNow);
						hub.SendRaw(pkt, Remote);
						o += take;
						continue;
					}
				}
				ev.WaitOne(50);
			}
		}

		public bool PollRead(int microSeconds) {
			lock (gate) { if (appIn.Count > 0) return true; }
			Tick();
			ev.WaitOne(Math.Max(1, microSeconds / 1000));
			lock (gate) { return appIn.Count > 0 || State == 3; }
		}
		public int Avail { get { lock (gate) return appIn.Count; } }
		public void Close() {
			lock (gate) {
				if (State == 2) SendPkt(1, SendId, seq, ack, null);
				State = 3;
			}
			hub.Remove(this);
		}
	}

	internal sealed class UtpPeerIo : PeerIo {
		UtpConn c;
		byte[] push = new byte[0];
		int pushOff;
		public UtpPeerIo(UtpConn c) { this.c = c; Transport = "uTP"; }
		public void Unread(byte[] buf, int off, int n) {
			byte[] nb = new byte[n + (push.Length - pushOff)];
			Buffer.BlockCopy(buf, off, nb, 0, n);
			if (push.Length - pushOff > 0) Buffer.BlockCopy(push, pushOff, nb, n, push.Length - pushOff);
			push = nb; pushOff = 0;
		}
		public override bool ReadExact(byte[] buf, int off, int n, int timeoutMs) {
			int got = 0;
			while (got < n && pushOff < push.Length) buf[off + got++] = push[pushOff++];
			if (pushOff >= push.Length) { push = new byte[0]; pushOff = 0; }
			if (got >= n) return true;
			return c.ReadExact(buf, off + got, n - got, timeoutMs);
		}
		public override void Write(byte[] buf, int n) { c.Write(buf, n); }
		public override bool PollRead(int microSeconds) {
			if (pushOff < push.Length) return true;
			return c.PollRead(microSeconds);
		}
		public override int Available {
			get {
				int a = push.Length - pushOff;
				if (a < 0) a = 0;
				return a + c.Avail;
			}
		}
		public override void Close() { c.Close(); }
	}

	internal sealed class UtpHub {
		Engine eng;
		UdpClient udp;
		VpnUdpSock vudp;
		Thread thr;
		volatile bool run;
		readonly object gate = new object();
		readonly Dictionary<string, UtpConn> map = new Dictionary<string, UtpConn>();
		public int Port;

		public UtpHub() { }
		public UtpHub(Engine e) { this.eng = e; }

		public bool Start(int port) {
			if (VpnHub.HasConfig && !VpnHub.TunnelOn) return false;
			try {
				if (VpnHub.HasConfig) {
					vudp = VpnHub.BindUdp(port);
					Port = vudp.locPort;
				} else {
					udp = new UdpClient(port);
					Port = ((IPEndPoint)udp.Client.LocalEndPoint).Port;
				}
				run = true;
				thr = new Thread(RecvLoop);
				thr.IsBackground = true;
				thr.Start();
				return true;
			} catch { udp = null; vudp = null; return false; }
		}
		public void Stop() {
			run = false;
			try { if (udp != null) udp.Close(); } catch { }
			try { if (vudp != null) VpnHub.DropUdp(vudp); } catch { }
			udp = null; vudp = null;
		}
		public void SendRaw(byte[] pkt, IPEndPoint ep) {
			try {
				if (vudp != null) vudp.SendTo(pkt, ep);
				else if (udp != null) udp.Send(pkt, pkt.Length, ep);
			} catch { }
		}
		public void Remove(UtpConn c) {
			lock (gate) {
				string k = Key(c.Remote, c.RecvId);
				map.Remove(k);
			}
		}
		static string Key(IPEndPoint ep, int recvId) {
			return ep.Address + ":" + ep.Port.ToString(CultureInfo.InvariantCulture) + ":" + recvId.ToString(CultureInfo.InvariantCulture);
		}
		public void Register(UtpConn c) {
			lock (gate) map[Key(c.Remote, c.RecvId)] = c;
		}
		public UtpConn Connect(string host, int port, int timeoutMs) {
			if (VpnHub.HasConfig && !VpnHub.TunnelOn) return null;
			UtpConn c = new UtpConn(this);
			if (!c.Connect(host, port, timeoutMs)) return null;
			return c;
		}
		void RecvLoop() {
			IPEndPoint any = new IPEndPoint(IPAddress.Any, 0);
			while (run) {
				try {
					byte[] pkt = null;
					IPEndPoint from = null;
					if (vudp != null) {
						if (!vudp.Recv(250, out pkt, out from)) continue;
					} else {
						if (udp == null) break;
						udp.Client.ReceiveTimeout = 250;
						pkt = udp.Receive(ref any);
						from = new IPEndPoint(any.Address, any.Port);
					}
					if (pkt == null || pkt.Length < 20) continue;
					int connId = (pkt[2] << 8) | pkt[3];
					int type = (pkt[0] >> 4) & 0xF;
					UtpConn c = null;
					lock (gate) {
						foreach (KeyValuePair<string, UtpConn> kv in map) {
							if (kv.Value.Remote != null && kv.Value.Remote.Address.Equals(from.Address) && kv.Value.Remote.Port == from.Port && kv.Value.RecvId == connId) {
								c = kv.Value; break;
							}
						}
					}
					if (c == null && type == 4) {
						c = new UtpConn(this);
						c.Remote = from;
						c.RecvId = connId + 1;
						c.SendId = connId;
						ushort synSeq = (ushort)((pkt[16] << 8) | pkt[17]);
						lock (gate) map[Key(from, c.RecvId)] = c;
						c.AcceptSyn(synSeq);
						Session.DispatchUtp(c);
					} else if (c != null) c.OnPacket(pkt);
				} catch (SocketException) {
				} catch { if (!run) break; }
			}
		}
	}

	internal static class Blake2s {
		static readonly uint[] IV = new uint[] { 0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19 };
		static readonly int[][] S = new int[][] {
			new int[]{0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15},
			new int[]{14,10,4,8,9,15,13,6,1,12,0,2,11,7,5,3},
			new int[]{11,8,12,0,5,2,15,13,10,14,3,6,7,1,9,4},
			new int[]{7,9,3,1,13,12,11,14,2,6,5,10,4,0,15,8},
			new int[]{9,0,5,7,2,4,10,15,14,1,11,12,6,8,3,13},
			new int[]{2,12,6,10,0,11,8,3,4,13,7,5,15,14,1,9},
			new int[]{12,5,1,15,14,13,4,10,0,7,6,3,9,2,8,11},
			new int[]{13,11,7,14,12,1,3,9,5,0,15,4,8,6,2,10},
			new int[]{6,15,14,9,11,3,0,8,12,2,13,7,1,4,10,5},
			new int[]{10,2,8,4,7,6,1,5,15,11,9,14,3,12,13,0}
		};
		static uint R(uint x, int n) { return (x >> n) | (x << (32 - n)); }
		static void G(uint[] v, int a, int b, int c, int d, uint x, uint y) {
			v[a] = v[a] + v[b] + x; v[d] = R(v[d] ^ v[a], 16);
			v[c] = v[c] + v[d]; v[b] = R(v[b] ^ v[c], 12);
			v[a] = v[a] + v[b] + y; v[d] = R(v[d] ^ v[a], 8);
			v[c] = v[c] + v[d]; v[b] = R(v[b] ^ v[c], 7);
		}
		static void Compress(uint[] h, byte[] block, ulong t, bool last) {
			uint[] v = new uint[16]; uint[] m = new uint[16];
			for (int i = 0; i < 8; i++) { v[i] = h[i]; v[i + 8] = IV[i]; }
			v[12] ^= (uint)t; v[13] ^= (uint)(t >> 32);
			if (last) v[14] = ~v[14];
			for (int i = 0; i < 16; i++) m[i] = BitConverter.ToUInt32(block, i * 4);
			for (int r = 0; r < 10; r++) {
				int[] s = S[r];
				G(v, 0, 4, 8, 12, m[s[0]], m[s[1]]); G(v, 1, 5, 9, 13, m[s[2]], m[s[3]]);
				G(v, 2, 6, 10, 14, m[s[4]], m[s[5]]); G(v, 3, 7, 11, 15, m[s[6]], m[s[7]]);
				G(v, 0, 5, 10, 15, m[s[8]], m[s[9]]); G(v, 1, 6, 11, 12, m[s[10]], m[s[11]]);
				G(v, 2, 7, 8, 13, m[s[12]], m[s[13]]); G(v, 3, 4, 9, 14, m[s[14]], m[s[15]]);
			}
			for (int i = 0; i < 8; i++) h[i] ^= v[i] ^ v[i + 8];
		}
		public static byte[] Hash(byte[] data, int outLen) { return HashKeyed(null, data, outLen); }
		public static byte[] HashKeyed(byte[] key, byte[] data, int outLen) {
			if (data == null) data = new byte[0];
			uint[] h = (uint[])IV.Clone();
			int klen = key == null ? 0 : key.Length;
			h[0] ^= 0x01010000U ^ ((uint)klen << 8) ^ (uint)outLen;
			byte[] block = new byte[64];
			ulong t = 0;
			int off = 0;
			if (klen > 0) {
				Buffer.BlockCopy(key, 0, block, 0, klen);
				t = 64; Compress(h, block, t, data.Length == 0); Array.Clear(block, 0, 64);
			}
			if (data.Length > 0 || klen == 0) {
				while (off + 64 < data.Length) {
					Buffer.BlockCopy(data, off, block, 0, 64); t += 64; Compress(h, block, t, false); off += 64;
				}
				Array.Clear(block, 0, 64);
				int left = data.Length - off;
				if (left > 0) Buffer.BlockCopy(data, off, block, 0, left);
				t += (ulong)left;
				Compress(h, block, t, true);
			}
			byte[] hs = new byte[32];
			for (int i = 0; i < 8; i++) Buffer.BlockCopy(BitConverter.GetBytes(h[i]), 0, hs, i * 4, 4);
			byte[] o = new byte[outLen]; Buffer.BlockCopy(hs, 0, o, 0, outLen); return o;
		}
		public static byte[] Hmac(byte[] key, byte[] data) {
			byte[] k = key.Length > 64 ? Hash(key, 32) : key;
			byte[] ip = new byte[64]; byte[] op = new byte[64];
			for (int i = 0; i < 64; i++) { ip[i] = 0x36; op[i] = 0x5c; }
			for (int i = 0; i < k.Length; i++) { ip[i] ^= k[i]; op[i] ^= k[i]; }
			byte[] inner = new byte[64 + data.Length];
			Buffer.BlockCopy(ip, 0, inner, 0, 64); Buffer.BlockCopy(data, 0, inner, 64, data.Length);
			byte[] ih = Hash(inner, 32);
			byte[] outer = new byte[96];
			Buffer.BlockCopy(op, 0, outer, 0, 64); Buffer.BlockCopy(ih, 0, outer, 64, 32);
			return Hash(outer, 32);
		}
		public static byte[] Mac16(byte[] key, byte[] data) { return HashKeyed(key, data, 16); }
	}

	internal static class ChaChaPoly {
		static readonly byte[] NoAd = new byte[0];
		static uint Rotl(uint x, int n) { return (x << n) | (x >> (32 - n)); }
		static uint Le32(byte[] b, int o) {
			return (uint)b[o] | ((uint)b[o + 1] << 8) | ((uint)b[o + 2] << 16) | ((uint)b[o + 3] << 24);
		}
		static void St32(byte[] b, int o, uint v) {
			b[o] = (byte)v; b[o + 1] = (byte)(v >> 8); b[o + 2] = (byte)(v >> 16); b[o + 3] = (byte)(v >> 24);
		}
		static void Qr(uint[] s, int a, int b, int c, int d) {
			s[a] += s[b]; s[d] = Rotl(s[d] ^ s[a], 16);
			s[c] += s[d]; s[b] = Rotl(s[b] ^ s[c], 12);
			s[a] += s[b]; s[d] = Rotl(s[d] ^ s[a], 8);
			s[c] += s[d]; s[b] = Rotl(s[b] ^ s[c], 7);
		}
		static void Block(byte[] key, byte[] nonce, uint counter, uint[] s, uint[] w, byte[] out64) {
			s[0] = 0x61707865; s[1] = 0x3320646e; s[2] = 0x79622d32; s[3] = 0x6b206574;
			s[4] = Le32(key, 0); s[5] = Le32(key, 4); s[6] = Le32(key, 8); s[7] = Le32(key, 12);
			s[8] = Le32(key, 16); s[9] = Le32(key, 20); s[10] = Le32(key, 24); s[11] = Le32(key, 28);
			s[12] = counter;
			s[13] = Le32(nonce, 0); s[14] = Le32(nonce, 4); s[15] = Le32(nonce, 8);
			for (int i = 0; i < 16; i++) w[i] = s[i];
			for (int r = 0; r < 10; r++) {
				Qr(w, 0, 4, 8, 12); Qr(w, 1, 5, 9, 13); Qr(w, 2, 6, 10, 14); Qr(w, 3, 7, 11, 15);
				Qr(w, 0, 5, 10, 15); Qr(w, 1, 6, 11, 12); Qr(w, 2, 7, 8, 13); Qr(w, 3, 4, 9, 14);
			}
			for (int i = 0; i < 16; i++) St32(out64, i * 4, w[i] + s[i]);
		}
		[ThreadStatic] static uint[] tsS;
		[ThreadStatic] static uint[] tsW;
		[ThreadStatic] static byte[] tsBlk;
		static uint[] S16() { uint[] a = tsS; if (a == null) { a = new uint[16]; tsS = a; } return a; }
		static uint[] W16() { uint[] a = tsW; if (a == null) { a = new uint[16]; tsW = a; } return a; }
		static byte[] B64() { byte[] a = tsBlk; if (a == null) { a = new byte[64]; tsBlk = a; } return a; }
		static void XorChaCha(byte[] key, byte[] nonce, uint ctr, byte[] src, int so, int n, byte[] dst, int dof) {
			uint[] st = S16(); uint[] w = W16(); byte[] blk = B64();
			int off = 0;
			while (off < n) {
				Block(key, nonce, ctr++, st, w, blk);
				int take = n - off; if (take > 64) take = 64;
				for (int i = 0; i < take; i++) dst[dof + off + i] = (byte)(src[so + off + i] ^ blk[i]);
				off += take;
			}
		}
		static void PolyBlocks(ref uint h0, ref uint h1, ref uint h2, ref uint h3, ref uint h4,
			uint r0, uint r1, uint r2, uint r3, uint r4, uint s1, uint s2, uint s3, uint s4,
			byte[] m, int off, int len) {
			uint hh0 = h0, hh1 = h1, hh2 = h2, hh3 = h3, hh4 = h4;
			int end = off + len;
			while (off + 16 <= end) {
				hh0 += Le32(m, off) & 0x3ffffff;
				hh1 += (Le32(m, off + 3) >> 2) & 0x3ffffff;
				hh2 += (Le32(m, off + 6) >> 4) & 0x3ffffff;
				hh3 += (Le32(m, off + 9) >> 6) & 0x3ffffff;
				hh4 += (Le32(m, off + 12) >> 8) | (1u << 24);
				ulong d0 = (ulong)hh0 * r0 + (ulong)hh1 * s4 + (ulong)hh2 * s3 + (ulong)hh3 * s2 + (ulong)hh4 * s1;
				ulong d1 = (ulong)hh0 * r1 + (ulong)hh1 * r0 + (ulong)hh2 * s4 + (ulong)hh3 * s3 + (ulong)hh4 * s2;
				ulong d2 = (ulong)hh0 * r2 + (ulong)hh1 * r1 + (ulong)hh2 * r0 + (ulong)hh3 * s4 + (ulong)hh4 * s3;
				ulong d3 = (ulong)hh0 * r3 + (ulong)hh1 * r2 + (ulong)hh2 * r1 + (ulong)hh3 * r0 + (ulong)hh4 * s4;
				ulong d4 = (ulong)hh0 * r4 + (ulong)hh1 * r3 + (ulong)hh2 * r2 + (ulong)hh3 * r1 + (ulong)hh4 * r0;
				uint c = (uint)(d0 >> 26); hh0 = (uint)d0 & 0x3ffffff; d1 += c;
				c = (uint)(d1 >> 26); hh1 = (uint)d1 & 0x3ffffff; d2 += c;
				c = (uint)(d2 >> 26); hh2 = (uint)d2 & 0x3ffffff; d3 += c;
				c = (uint)(d3 >> 26); hh3 = (uint)d3 & 0x3ffffff; d4 += c;
				c = (uint)(d4 >> 26); hh4 = (uint)d4 & 0x3ffffff;
				hh0 += c * 5; c = hh0 >> 26; hh0 &= 0x3ffffff; hh1 += c;
				off += 16;
			}
			h0 = hh0; h1 = hh1; h2 = hh2; h3 = hh3; h4 = hh4;
		}
		static void PolyMsg(ref uint h0, ref uint h1, ref uint h2, ref uint h3, ref uint h4,
			uint r0, uint r1, uint r2, uint r3, uint r4, uint s1, uint s2, uint s3, uint s4,
			byte[] m, int len) {
			if (m == null || len <= 0) return;
			int full = len & ~15;
			if (full > 0) PolyBlocks(ref h0, ref h1, ref h2, ref h3, ref h4, r0, r1, r2, r3, r4, s1, s2, s3, s4, m, 0, full);
			int left = len - full;
			if (left > 0) {
				byte[] p = new byte[16];
				Buffer.BlockCopy(m, full, p, 0, left);
				PolyBlocks(ref h0, ref h1, ref h2, ref h3, ref h4, r0, r1, r2, r3, r4, s1, s2, s3, s4, p, 0, 16);
			}
		}
		static void Poly(byte[] otk, byte[] ad, byte[] ct, int ctLen, byte[] tag) {
			uint t0 = Le32(otk, 0), t1 = Le32(otk, 4), t2 = Le32(otk, 8), t3 = Le32(otk, 12);
			uint r0 = t0 & 0x3ffffff;
			uint r1 = ((t0 >> 26) | (t1 << 6)) & 0x3ffff03;
			uint r2 = ((t1 >> 20) | (t2 << 12)) & 0x3ffc0ff;
			uint r3 = ((t2 >> 14) | (t3 << 18)) & 0x3f03fff;
			uint r4 = (t3 >> 8) & 0x00fffff;
			uint s1 = r1 * 5, s2 = r2 * 5, s3 = r3 * 5, s4 = r4 * 5;
			uint p0 = Le32(otk, 16), p1 = Le32(otk, 20), p2 = Le32(otk, 24), p3 = Le32(otk, 28);
			uint h0 = 0, h1 = 0, h2 = 0, h3 = 0, h4 = 0;
			if (ad == null) ad = NoAd;
			PolyMsg(ref h0, ref h1, ref h2, ref h3, ref h4, r0, r1, r2, r3, r4, s1, s2, s3, s4, ad, ad.Length);
			PolyMsg(ref h0, ref h1, ref h2, ref h3, ref h4, r0, r1, r2, r3, r4, s1, s2, s3, s4, ct, ctLen);
			byte[] lens = new byte[16];
			St32(lens, 0, (uint)ad.Length); St32(lens, 4, (uint)((ulong)ad.Length >> 32));
			St32(lens, 8, (uint)ctLen); St32(lens, 12, 0);
			PolyBlocks(ref h0, ref h1, ref h2, ref h3, ref h4, r0, r1, r2, r3, r4, s1, s2, s3, s4, lens, 0, 16);
			uint c = h1 >> 26; h1 &= 0x3ffffff;
			h2 += c; c = h2 >> 26; h2 &= 0x3ffffff;
			h3 += c; c = h3 >> 26; h3 &= 0x3ffffff;
			h4 += c; c = h4 >> 26; h4 &= 0x3ffffff;
			h0 += c * 5; c = h0 >> 26; h0 &= 0x3ffffff;
			h1 += c;
			uint g0 = h0 + 5; c = g0 >> 26; g0 &= 0x3ffffff;
			uint g1 = h1 + c; c = g1 >> 26; g1 &= 0x3ffffff;
			uint g2 = h2 + c; c = g2 >> 26; g2 &= 0x3ffffff;
			uint g3 = h3 + c; c = g3 >> 26; g3 &= 0x3ffffff;
			uint g4 = h4 + c - (1u << 26);
			uint mask = (g4 >> 31) - 1u;
			g0 &= mask; g1 &= mask; g2 &= mask; g3 &= mask; g4 &= mask;
			mask = ~mask;
			h0 = (h0 & mask) | g0; h1 = (h1 & mask) | g1; h2 = (h2 & mask) | g2; h3 = (h3 & mask) | g3; h4 = (h4 & mask) | g4;
			h0 = (h0 | (h1 << 26)) & 0xffffffff; h1 = ((h1 >> 6) | (h2 << 20)) & 0xffffffff;
			h2 = ((h2 >> 12) | (h3 << 14)) & 0xffffffff; h3 = ((h3 >> 18) | (h4 << 8)) & 0xffffffff;
			ulong f = (ulong)h0 + p0; h0 = (uint)f;
			f = (ulong)h1 + p1 + (f >> 32); h1 = (uint)f;
			f = (ulong)h2 + p2 + (f >> 32); h2 = (uint)f;
			f = (ulong)h3 + p3 + (f >> 32); h3 = (uint)f;
			St32(tag, 0, h0); St32(tag, 4, h1); St32(tag, 8, h2); St32(tag, 12, h3);
		}
		static byte[] Nonce(ulong counter) {
			byte[] n = new byte[12]; St32(n, 4, (uint)counter); St32(n, 8, (uint)(counter >> 32)); return n;
		}
		public static byte[] Seal(byte[] key, ulong counter, byte[] plain, byte[] ad) {
			return SealNonce(key, Nonce(counter), plain, ad);
		}
		public static byte[] SealNonce(byte[] key, byte[] nonce, byte[] plain, byte[] ad) {
			if (plain == null) plain = NoAd;
			if (ad == null) ad = NoAd;
			byte[] otk = new byte[64]; Block(key, nonce, 0, S16(), W16(), otk);
			byte[] ct = new byte[plain.Length + 16];
			if (plain.Length > 0) XorChaCha(key, nonce, 1, plain, 0, plain.Length, ct, 0);
			byte[] tag = new byte[16]; Poly(otk, ad, ct, plain.Length, tag);
			Buffer.BlockCopy(tag, 0, ct, plain.Length, 16);
			return ct;
		}
		public static byte[] Open(byte[] key, ulong counter, byte[] cipher, byte[] ad) {
			if (cipher == null || cipher.Length < 16) return null;
			if (ad == null) ad = NoAd;
			int plen = cipher.Length - 16;
			byte[] nonce = Nonce(counter);
			byte[] otk = new byte[64]; Block(key, nonce, 0, S16(), W16(), otk);
			byte[] tag = new byte[16]; Poly(otk, ad, cipher, plen, tag);
			int diff = 0;
			for (int i = 0; i < 16; i++) diff |= tag[i] ^ cipher[plen + i];
			if (diff != 0) return null;
			byte[] plain = new byte[plen];
			if (plen > 0) XorChaCha(key, nonce, 1, cipher, 0, plen, plain, 0);
			return plain;
		}
	}

	internal static class X25519 {
		static readonly BigInteger P = (BigInteger.One << 255) - 19;
		static BigInteger Mod(BigInteger x) { x %= P; if (x.Sign < 0) x += P; return x; }
		static BigInteger Decode(byte[] b) {
			byte[] t = new byte[33]; Buffer.BlockCopy(b, 0, t, 0, 32); t[31] &= 127; return new BigInteger(t);
		}
		static byte[] Encode(BigInteger x) {
			x = Mod(x); byte[] t = x.ToByteArray(); byte[] o = new byte[32];
			Buffer.BlockCopy(t, 0, o, 0, t.Length > 32 ? 32 : t.Length); return o;
		}
		static void Cswap(ref BigInteger a, ref BigInteger b, int sw) {
			if (sw == 0) return; BigInteger t = a; a = b; b = t;
		}
		public static byte[] ScalarMult(byte[] n, byte[] p) {
			byte[] k = new byte[32]; Buffer.BlockCopy(n, 0, k, 0, 32);
			k[0] &= 248; k[31] &= 127; k[31] |= 64;
			BigInteger x1 = Decode(p), x2 = 1, z2 = 0, x3 = x1, z3 = 1;
			int swap = 0;
			for (int t = 254; t >= 0; t--) {
				int kt = (k[t >> 3] >> (t & 7)) & 1;
				swap ^= kt; Cswap(ref x2, ref x3, swap); Cswap(ref z2, ref z3, swap); swap = kt;
				BigInteger a = Mod(x2 + z2), aa = Mod(a * a), b = Mod(x2 - z2), bb = Mod(b * b);
				BigInteger e = Mod(aa - bb), c = Mod(x3 + z3), d = Mod(x3 - z3);
				BigInteger da = Mod(d * a), cb = Mod(c * b);
				x3 = Mod((da + cb) * (da + cb)); z3 = Mod(x1 * (da - cb) * (da - cb));
				x2 = Mod(aa * bb); z2 = Mod(e * (aa + Mod(121665 * e)));
			}
			Cswap(ref x2, ref x3, swap); Cswap(ref z2, ref z3, swap);
			return Encode(Mod(x2 * BigInteger.ModPow(z2, P - 2, P)));
		}
		public static byte[] PublicFromPrivate(byte[] priv) {
			byte[] nine = new byte[32]; nine[0] = 9; return ScalarMult(priv, nine);
		}
		public static byte[] RandomPrivate() {
			byte[] k = new byte[32]; new RNGCryptoServiceProvider().GetBytes(k);
			k[0] &= 248; k[31] &= 127; k[31] |= 64; return k;
		}
	}

	internal static class WgKdf {
		public static void Kdf1(byte[] ck, byte[] data, byte[] o1) {
			byte[] t = Blake2s.Hmac(ck, data); byte[] o = Blake2s.Hmac(t, new byte[] { 1 }); Buffer.BlockCopy(o, 0, o1, 0, 32);
		}
		public static void Kdf2(byte[] ck, byte[] data, byte[] o1, byte[] o2) {
			byte[] t = Blake2s.Hmac(ck, data);
			byte[] a = Blake2s.Hmac(t, new byte[] { 1 }); Buffer.BlockCopy(a, 0, o1, 0, 32);
			byte[] mix = new byte[33]; Buffer.BlockCopy(a, 0, mix, 0, 32); mix[32] = 2;
			byte[] b = Blake2s.Hmac(t, mix); Buffer.BlockCopy(b, 0, o2, 0, 32);
		}
		public static void Kdf3(byte[] ck, byte[] data, byte[] o1, byte[] o2, byte[] o3) {
			byte[] t = Blake2s.Hmac(ck, data);
			byte[] a = Blake2s.Hmac(t, new byte[] { 1 }); Buffer.BlockCopy(a, 0, o1, 0, 32);
			byte[] m2 = new byte[33]; Buffer.BlockCopy(a, 0, m2, 0, 32); m2[32] = 2;
			byte[] b = Blake2s.Hmac(t, m2); Buffer.BlockCopy(b, 0, o2, 0, 32);
			byte[] m3 = new byte[33]; Buffer.BlockCopy(b, 0, m3, 0, 32); m3[32] = 3;
			byte[] c = Blake2s.Hmac(t, m3); Buffer.BlockCopy(c, 0, o3, 0, 32);
		}
		public static byte[] HashCat(byte[] a, byte[] b) {
			byte[] c = new byte[a.Length + b.Length]; Buffer.BlockCopy(a, 0, c, 0, a.Length); Buffer.BlockCopy(b, 0, c, a.Length, b.Length);
			return Blake2s.Hash(c, 32);
		}
	}

	internal sealed class VpnSeg {
		internal byte[] data;
		internal uint seq;
		internal DateTime sent;
	}

	internal sealed class VpnTcpStream : Stream {
		readonly VpnTcp t;
		public VpnTcpStream(VpnTcp t) { this.t = t; }
		public override bool CanRead { get { return true; } }
		public override bool CanWrite { get { return true; } }
		public override bool CanSeek { get { return false; } }
		public override long Length { get { throw new NotSupportedException(); } }
		public override long Position { get { throw new NotSupportedException(); } set { throw new NotSupportedException(); } }
		public override void Flush() { }
		public override long Seek(long o, SeekOrigin s) { throw new NotSupportedException(); }
		public override void SetLength(long v) { throw new NotSupportedException(); }
		public override int Read(byte[] b, int o, int n) { return t.Read(b, o, n, 60000); }
		public override void Write(byte[] b, int o, int n) { t.Write(b, o, n); }
		protected override void Dispose(bool d) { try { t.Close(); } catch { } base.Dispose(d); }
	}

	internal sealed class VpnTcp {
		internal const int Mss = 1280;
		internal const int MaxFlight = 1024 * 1280;
		internal const int WScale = 8;
		internal uint remIp, locIp; internal ushort remPort, locPort;
		internal int state;
		internal uint sndNxt, sndUna, rcvNxt, iss, finSeq;
		internal bool finSeen;
		internal readonly Queue<byte[]> rxq = new Queue<byte[]>();
		internal int rxOff, rxAvail, dupAcks;
		internal uint peerWnd = 65535;
		internal int sndWScale;
		internal readonly Dictionary<uint, byte[]> ooo = new Dictionary<uint, byte[]>();
		internal readonly Queue<byte[]> pending = new Queue<byte[]>();
		internal readonly List<VpnSeg> flight = new List<VpnSeg>();
		internal readonly AutoResetEvent ev = new AutoResetEvent(false);
		internal readonly object gate = new object();
		internal DateTime lastTx = DateTime.UtcNow;
		internal bool rst;
		public int Available { get { lock (gate) return rxAvail; } }
		public bool Poll(int micro) {
			if (Available > 0) return true;
			ev.WaitOne(Math.Max(1, micro / 1000));
			return Available > 0 || state == 0 || state == 4 || rst;
		}
		public int Read(byte[] b, int o, int n, int timeoutMs) {
			DateTime dead = DateTime.UtcNow.AddMilliseconds(timeoutMs);
			int got = 0;
			while (got < n) {
				lock (gate) {
					while (got < n && rxq.Count > 0) {
						byte[] c = rxq.Peek();
						int ntake = n - got; int cleft = c.Length - rxOff;
						if (ntake > cleft) ntake = cleft;
						Buffer.BlockCopy(c, rxOff, b, o + got, ntake);
						rxOff += ntake; rxAvail -= ntake; got += ntake;
						if (rxOff >= c.Length) { rxq.Dequeue(); rxOff = 0; }
					}
				}
				if (got > 0) return got;
				if (state == 0 || state == 4 || rst) return got;
				int left = (int)(dead - DateTime.UtcNow).TotalMilliseconds;
				if (left <= 0) return got;
				ev.WaitOne(Math.Min(200, left));
			}
			return got;
		}
		int QueuedBytes() {
			int n = 0;
			foreach (byte[] p in pending) n += p.Length;
			for (int i = 0; i < flight.Count; i++) n += flight[i].data.Length;
			return n;
		}
		public void Write(byte[] b, int o, int n) {
			if (n <= 0 || state != 3) return;
			int off = 0;
			lock (gate) {
				while (off < n) {
					int take = n - off; if (take > Mss) take = Mss;
					byte[] seg = new byte[take];
					Buffer.BlockCopy(b, o + off, seg, 0, take);
					pending.Enqueue(seg);
					off += take;
				}
			}
			VpnHub.TcpPump(this);
			DateTime dead = DateTime.UtcNow.AddMilliseconds(30000);
			while (DateTime.UtcNow < dead) {
				lock (gate) {
					if (rst || state != 3) return;
					if (QueuedBytes() < 2097152) return;
				}
				ev.WaitOne(40);
			}
		}
		public void Close() {
			if (state == 3) {
				try { VpnHub.TcpSend(this, 0x11, null, sndNxt); } catch { }
			}
			state = 0; ev.Set(); VpnHub.DropTcp(this);
		}
	}

	internal sealed class VpnUdpSock {
		internal ushort locPort;
		internal readonly Queue<byte[]> rx = new Queue<byte[]>();
		internal readonly Queue<IPEndPoint> from = new Queue<IPEndPoint>();
		internal readonly AutoResetEvent ev = new AutoResetEvent(false);
		internal readonly object gate = new object();
		public void SendTo(byte[] data, IPEndPoint ep) { VpnHub.UdpSend(this, data, ep); }
		public bool Recv(int timeoutMs, out byte[] data, out IPEndPoint ep) {
			data = null; ep = null;
			DateTime dead = DateTime.UtcNow.AddMilliseconds(timeoutMs);
			while (true) {
				lock (gate) {
					if (rx.Count > 0) { data = rx.Dequeue(); ep = from.Dequeue(); return true; }
				}
				int left = (int)(dead - DateTime.UtcNow).TotalMilliseconds;
				if (left <= 0) return false;
				ev.WaitOne(Math.Min(200, left));
			}
		}
	}

	internal static class Tls1Prf {
		static byte[] PHash(HMAC hmac, byte[] seed, int n) {
			byte[] a = seed;
			byte[] o = new byte[n];
			int off = 0;
			while (off < n) {
				a = hmac.ComputeHash(a);
				byte[] inp = new byte[a.Length + seed.Length];
				Buffer.BlockCopy(a, 0, inp, 0, a.Length);
				Buffer.BlockCopy(seed, 0, inp, a.Length, seed.Length);
				byte[] b = hmac.ComputeHash(inp);
				int take = n - off; if (take > b.Length) take = b.Length;
				Buffer.BlockCopy(b, 0, o, off, take);
				off += take;
			}
			return o;
		}
		public static byte[] Prf(byte[] secret, string label, byte[] seed, int n) {
			byte[] lab = Encoding.ASCII.GetBytes(label);
			byte[] ls = new byte[lab.Length + seed.Length];
			Buffer.BlockCopy(lab, 0, ls, 0, lab.Length);
			Buffer.BlockCopy(seed, 0, ls, lab.Length, seed.Length);
			int half = (secret.Length + 1) / 2;
			byte[] s1 = new byte[half]; byte[] s2 = new byte[half];
			Buffer.BlockCopy(secret, 0, s1, 0, half);
			Buffer.BlockCopy(secret, secret.Length - half, s2, 0, half);
			byte[] p1, p2;
			using (HMACMD5 m = new HMACMD5(s1)) p1 = PHash(m, ls, n);
			using (HMACSHA1 s = new HMACSHA1(s2)) p2 = PHash(s, ls, n);
			byte[] o = new byte[n];
			for (int i = 0; i < n; i++) o[i] = (byte)(p1[i] ^ p2[i]);
			return o;
		}
	}

	internal static class AesGcmPt {
		static void GfMul(byte[] x, byte[] y) {
			byte[] z = new byte[16];
			byte[] v = new byte[16];
			Buffer.BlockCopy(y, 0, v, 0, 16);
			for (int i = 0; i < 16; i++) {
				for (int j = 7; j >= 0; j--) {
					if ((x[i] & (1 << j)) != 0) {
						for (int k = 0; k < 16; k++) z[k] ^= v[k];
					}
					bool lsb = (v[15] & 1) != 0;
					for (int k = 15; k > 0; k--) v[k] = (byte)((v[k] >> 1) | (v[k - 1] << 7));
					v[0] >>= 1;
					if (lsb) v[0] ^= 0xE1;
				}
			}
			Buffer.BlockCopy(z, 0, x, 0, 16);
		}
		static void Xor16(byte[] a, byte[] b, int bo) {
			for (int i = 0; i < 16; i++) a[i] ^= b[bo + i];
		}
		static ICryptoTransform AesEnc(byte[] key, out Aes aes) {
			aes = Aes.Create();
			aes.Mode = CipherMode.ECB; aes.Padding = PaddingMode.None; aes.KeySize = 256; aes.Key = key;
			return aes.CreateEncryptor();
		}
		static void AesEcb(ICryptoTransform e, byte[] block) {
			e.TransformBlock(block, 0, 16, block, 0);
		}
		static void Ctr(ICryptoTransform enc, byte[] nonce, uint start, byte[] src, int so, int n, byte[] dst, int dof) {
			byte[] ctr = new byte[16];
			Buffer.BlockCopy(nonce, 0, ctr, 0, 12);
			byte[] ks = new byte[16];
			int off = 0; uint c = start;
			while (off < n) {
				ctr[12] = (byte)(c >> 24); ctr[13] = (byte)(c >> 16); ctr[14] = (byte)(c >> 8); ctr[15] = (byte)c;
				Buffer.BlockCopy(ctr, 0, ks, 0, 16);
				AesEcb(enc, ks);
				int take = n - off; if (take > 16) take = 16;
				for (int i = 0; i < take; i++) dst[dof + off + i] = (byte)(src[so + off + i] ^ ks[i]);
				off += take; c++;
			}
		}
		static void Ghash(byte[] H, byte[] ad, byte[] ct, int ctLen, byte[] out16) {
			byte[] y = new byte[16];
			int i = 0;
			if (ad != null) {
				while (i + 16 <= ad.Length) { Xor16(y, ad, i); GfMul(y, H); i += 16; }
				if (i < ad.Length) {
					byte[] p = new byte[16]; Buffer.BlockCopy(ad, i, p, 0, ad.Length - i);
					Xor16(y, p, 0); GfMul(y, H);
				}
			}
			i = 0;
			while (i + 16 <= ctLen) { Xor16(y, ct, i); GfMul(y, H); i += 16; }
			if (i < ctLen) {
				byte[] p = new byte[16]; Buffer.BlockCopy(ct, i, p, 0, ctLen - i);
				Xor16(y, p, 0); GfMul(y, H);
			}
			byte[] len = new byte[16];
			ulong al = (ulong)(ad == null ? 0 : ad.Length) * 8UL;
			ulong cl = (ulong)ctLen * 8UL;
			for (int k = 0; k < 8; k++) { len[7 - k] = (byte)al; al >>= 8; len[15 - k] = (byte)cl; cl >>= 8; }
			Xor16(y, len, 0); GfMul(y, H);
			Buffer.BlockCopy(y, 0, out16, 0, 16);
		}
		public static byte[] Seal(byte[] key, byte[] nonce12, byte[] ad, byte[] pt) {
			if (pt == null) pt = new byte[0];
			if (ad == null) ad = new byte[0];
			Aes aes; ICryptoTransform enc = AesEnc(key, out aes);
			try {
				byte[] H = new byte[16]; AesEcb(enc, H);
				byte[] ct = new byte[pt.Length + 16];
				Ctr(enc, nonce12, 2, pt, 0, pt.Length, ct, 0);
				byte[] s = new byte[16]; Ghash(H, ad, ct, pt.Length, s);
				byte[] t0 = new byte[16]; Ctr(enc, nonce12, 1, s, 0, 16, t0, 0);
				Buffer.BlockCopy(t0, 0, ct, pt.Length, 16);
				return ct;
			} finally { enc.Dispose(); aes.Dispose(); }
		}
		public static byte[] Open(byte[] key, byte[] nonce12, byte[] ad, byte[] ctTag) {
			if (ctTag == null || ctTag.Length < 16) return null;
			if (ad == null) ad = new byte[0];
			int plen = ctTag.Length - 16;
			Aes aes; ICryptoTransform enc = AesEnc(key, out aes);
			try {
				byte[] H = new byte[16]; AesEcb(enc, H);
				byte[] s = new byte[16]; Ghash(H, ad, ctTag, plen, s);
				byte[] t0 = new byte[16]; Ctr(enc, nonce12, 1, s, 0, 16, t0, 0);
				int diff = 0;
				for (int i = 0; i < 16; i++) diff |= t0[i] ^ ctTag[plen + i];
				if (diff != 0) return null;
				byte[] pt = new byte[plen];
				if (plen > 0) Ctr(enc, nonce12, 2, ctTag, 0, plen, pt, 0);
				return pt;
			} finally { enc.Dispose(); aes.Dispose(); }
		}
		public static byte[] CtrCrypt(byte[] key, byte[] iv16, byte[] pt) {
			byte[] nonce = new byte[12]; Buffer.BlockCopy(iv16, 0, nonce, 0, 12);
			uint start = ((uint)iv16[12] << 24) | ((uint)iv16[13] << 16) | ((uint)iv16[14] << 8) | iv16[15];
			byte[] o = new byte[pt.Length];
			Aes aes; ICryptoTransform enc = AesEnc(key, out aes);
			try { Ctr(enc, nonce, start, pt, 0, pt.Length, o, 0); return o; }
			finally { enc.Dispose(); aes.Dispose(); }
		}
	}

	internal static class Pem {
		public static byte[] Block(string text, string name) {
			string a = "-----BEGIN " + name + "-----";
			string b = "-----END " + name + "-----";
			int i = text.IndexOf(a, StringComparison.Ordinal);
			if (i < 0) return null;
			int j = text.IndexOf(b, i, StringComparison.Ordinal);
			if (j < 0) return null;
			string body = text.Substring(i + a.Length, j - (i + a.Length)).Replace("\r", "").Replace("\n", "").Replace(" ", "");
			try { return Convert.FromBase64String(body); } catch { return null; }
		}
		public static string Tag(string text, string name) {
			string a = "<" + name + ">";
			string b = "</" + name + ">";
			int i = text.IndexOf(a, StringComparison.OrdinalIgnoreCase);
			if (i < 0) return null;
			int j = text.IndexOf(b, i, StringComparison.OrdinalIgnoreCase);
			if (j < 0) return null;
			return text.Substring(i + a.Length, j - (i + a.Length));
		}
		public static byte[] HexKey(string text) {
			string a = "-----BEGIN OpenVPN Static key V1-----";
			string b = "-----END OpenVPN Static key V1-----";
			int i = text.IndexOf(a, StringComparison.Ordinal);
			if (i < 0) return null;
			int j = text.IndexOf(b, i, StringComparison.Ordinal);
			if (j < 0) return null;
			string body = text.Substring(i + a.Length, j - (i + a.Length));
			StringBuilder sb = new StringBuilder();
			for (int k = 0; k < body.Length; k++) {
				char c = body[k];
				if ((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) sb.Append(c);
			}
			if ((sb.Length & 1) != 0) return null;
			byte[] o = new byte[sb.Length / 2];
			for (int k = 0; k < o.Length; k++)
				o[k] = byte.Parse(sb.ToString(k * 2, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture);
			return o;
		}
		static int DerLen(byte[] d, ref int i) {
			int l = d[i++];
			if ((l & 0x80) == 0) return l;
			int n = l & 0x7F; int v = 0;
			for (int k = 0; k < n; k++) v = (v << 8) | d[i++];
			return v;
		}
		static byte[] DerInt(byte[] d, ref int i) {
			if (d[i++] != 0x02) throw new InvalidDataException("der int");
			int n = DerLen(d, ref i);
			while (n > 1 && d[i] == 0) { i++; n--; }
			byte[] v = new byte[n + 1];
			Buffer.BlockCopy(d, i, v, 1, n);
			i += n;
			return v;
		}
		static RSAParameters RsaPkcs1(byte[] der) {
			int i = 0;
			if (der[i++] != 0x30) throw new InvalidDataException("seq");
			DerLen(der, ref i);
			DerInt(der, ref i);
			RSAParameters p = new RSAParameters();
			p.Modulus = Skip0(DerInt(der, ref i));
			p.Exponent = Skip0(DerInt(der, ref i));
			p.D = Skip0(DerInt(der, ref i));
			p.P = Skip0(DerInt(der, ref i));
			p.Q = Skip0(DerInt(der, ref i));
			p.DP = Skip0(DerInt(der, ref i));
			p.DQ = Skip0(DerInt(der, ref i));
			p.InverseQ = Skip0(DerInt(der, ref i));
			return p;
		}
		static byte[] Skip0(byte[] v) {
			if (v.Length > 1 && v[0] == 0) {
				byte[] o = new byte[v.Length - 1]; Buffer.BlockCopy(v, 1, o, 0, o.Length); return o;
			}
			return v;
		}
		public static RSACryptoServiceProvider RsaFromPem(string text) {
			byte[] der = Block(text, "RSA PRIVATE KEY");
			if (der == null) {
				byte[] pkcs8 = Block(text, "PRIVATE KEY");
				if (pkcs8 == null) return null;
				int i = 0;
				if (pkcs8[i++] != 0x30) return null;
				DerLen(pkcs8, ref i);
				DerInt(pkcs8, ref i);
				if (pkcs8[i++] != 0x30) return null;
				int sl = DerLen(pkcs8, ref i); i += sl;
				if (pkcs8[i++] != 0x04) return null;
				int ol = DerLen(pkcs8, ref i);
				der = new byte[ol]; Buffer.BlockCopy(pkcs8, i, der, 0, ol);
			}
			RSAParameters p = RsaPkcs1(der);
			CspParameters cp = new CspParameters();
			cp.KeyContainerName = Guid.NewGuid().ToString("N");
			RSACryptoServiceProvider rsa = new RSACryptoServiceProvider(cp);
			rsa.PersistKeyInCsp = false;
			rsa.ImportParameters(p);
			return rsa;
		}
		public static X509Certificate2 CertFromPem(string text) {
			byte[] der = Block(text, "CERTIFICATE");
			if (der == null) return null;
			return new X509Certificate2(der);
		}
		public static X509Certificate2 CertWithKey(byte[] der, RSACryptoServiceProvider rsa) {
			if (der == null || rsa == null) return null;
			X509Certificate2 c = new X509Certificate2(der);
			try { c.PrivateKey = rsa; } catch { }
			try {
				byte[] pfx = c.Export(X509ContentType.Pkcs12, "pt");
				return new X509Certificate2(pfx, "pt", X509KeyStorageFlags.Exportable | X509KeyStorageFlags.UserKeySet);
			} catch { return c; }
		}
	}

	internal sealed class OvpnCtl : Stream {
		internal readonly object gate = new object();
		internal readonly Queue<byte> rx = new Queue<byte>();
		internal readonly AutoResetEvent ev = new AutoResetEvent(false);
		internal volatile bool dead;
		public override bool CanRead { get { return true; } }
		public override bool CanWrite { get { return true; } }
		public override bool CanSeek { get { return false; } }
		public override long Length { get { throw new NotSupportedException(); } }
		public override long Position { get { throw new NotSupportedException(); } set { throw new NotSupportedException(); } }
		public override void Flush() { }
		public override long Seek(long o, SeekOrigin s) { throw new NotSupportedException(); }
		public override void SetLength(long v) { throw new NotSupportedException(); }
		public Action<byte[]> OnWrite;
		public override int Read(byte[] b, int o, int n) {
			DateTime deadAt = DateTime.UtcNow.AddSeconds(60);
			int got = 0;
			while (got < n) {
				lock (gate) {
					while (got < n && rx.Count > 0) b[o + got++] = rx.Dequeue();
				}
				if (got > 0) return got;
				if (dead) return 0;
				int left = (int)(deadAt - DateTime.UtcNow).TotalMilliseconds;
				if (left <= 0) return 0;
				ev.WaitOne(Math.Min(200, left));
			}
			return got;
		}
		public override void Write(byte[] b, int o, int n) {
			byte[] p = new byte[n]; Buffer.BlockCopy(b, o, p, 0, n);
			Action<byte[]> w = OnWrite;
			if (w != null) w(p);
		}
		public void Push(byte[] d, int off, int n) {
			lock (gate) { for (int i = 0; i < n; i++) rx.Enqueue(d[off + i]); }
			ev.Set();
		}
	}

	internal sealed class OvpnSess {
		public string RemoteHost;
		public int RemotePort = 1194;
		public IPEndPoint Endpoint;
		public byte[] TlsCryptKey;
		public string CipherName = "AES-256-GCM";
		public int TunMtu = 1500;
		public string User = "", Pass = "";
		static readonly byte[] PingMagic = new byte[] {
			0x2A, 0x18, 0x7B, 0xF3, 0x64, 0x1E, 0xB4, 0xCB, 0x07, 0xED, 0x2C, 0x0E, 0x7A, 0x16, 0x4F, 0x08
		};
		byte[] locSid = new byte[8], remSid = new byte[8];
		byte[] encKe, encKa, decKe, decKa;
		uint wrapPid = 1;
		uint msgPid = 1;
		readonly Dictionary<uint, byte[]> sendTls = new Dictionary<uint, byte[]>();
		readonly Dictionary<uint, DateTime> sendAt = new Dictionary<uint, DateTime>();
		readonly Dictionary<uint, int> sendOp = new Dictionary<uint, int>();
		readonly List<uint> pendingAck = new List<uint>();
		uint nextIn;
		readonly Dictionary<uint, byte[]> ooo = new Dictionary<uint, byte[]>();
		readonly OvpnCtl ctl = new OvpnCtl();
		readonly object gate = new object();
		byte[] sendCk, sendIv, recvCk, recvIv;
		uint dataPid = 1;
		int peerId = 0xFFFFFF;
		volatile bool keysUp;
		SslStream ssl;
		X509Certificate2 caCert, clCert;
		byte[] kmClient, kmServer;

		public static bool TryParse(string text, out OvpnSess s, out string err) {
			s = null; err = "";
			if (string.IsNullOrEmpty(text)) { err = "empty config"; return false; }
			if (text.IndexOf("tls-crypt-v2", StringComparison.OrdinalIgnoreCase) >= 0) {
				err = "OpenVPN tls-crypt-v2 is not supported.";
				return false;
			}
			bool looks = text.IndexOf("remote ", StringComparison.OrdinalIgnoreCase) >= 0
				|| text.IndexOf("remote\t", StringComparison.OrdinalIgnoreCase) >= 0
				|| text.IndexOf("<tls-crypt>", StringComparison.OrdinalIgnoreCase) >= 0
				|| text.IndexOf("\nclient", StringComparison.OrdinalIgnoreCase) >= 0;
			if (!looks) { err = "not an OpenVPN config"; return false; }
			OvpnSess o = new OvpnSess();
			string proto = "udp";
			string host = null; int port = 1194;
			string[] lines = text.Replace("\r", "").Split('\n');
			for (int i = 0; i < lines.Length; i++) {
				string ln = lines[i].Trim();
				if (ln.Length == 0 || ln[0] == '#' || ln[0] == ';' || ln[0] == '<') continue;
				string[] p = ln.Split(new char[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
				if (p.Length == 0) continue;
				string k = p[0].ToLowerInvariant();
				if (k == "remote" && p.Length >= 2) {
					if (host == null) {
						host = p[1];
						if (p.Length >= 3) int.TryParse(p[2], NumberStyles.Integer, CultureInfo.InvariantCulture, out port);
						if (p.Length >= 4) proto = p[3].ToLowerInvariant();
					}
				} else if (k == "proto" && p.Length >= 2) proto = p[1].ToLowerInvariant();
				else if (k == "cipher" && p.Length >= 2) o.CipherName = p[1].ToUpperInvariant();
				else if (k == "tun-mtu" && p.Length >= 2) int.TryParse(p[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out o.TunMtu);
				else if (k == "port" && p.Length >= 2 && host == null) int.TryParse(p[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out port);
			}
			if (string.IsNullOrEmpty(host)) { err = "OpenVPN config missing remote"; return false; }
			if (proto.IndexOf("tcp", StringComparison.Ordinal) >= 0) {
				err = "OpenVPN TCP is not supported. Use UDP.";
				return false;
			}
			if (proto.IndexOf("udp6", StringComparison.Ordinal) >= 0) {
				err = "OpenVPN IPv6 is not supported.";
				return false;
			}
			string cryptBlock = Pem.Tag(text, "tls-crypt");
			if (cryptBlock == null && text.IndexOf("tls-crypt", StringComparison.OrdinalIgnoreCase) < 0) {
				err = "OpenVPN config needs tls-crypt.";
				return false;
			}
			o.TlsCryptKey = Pem.HexKey(cryptBlock != null ? cryptBlock : text);
			if (o.TlsCryptKey == null || o.TlsCryptKey.Length < 256) {
				err = "OpenVPN config needs a tls-crypt key.";
				return false;
			}
			string caPem = Pem.Tag(text, "ca");
			string certPem = Pem.Tag(text, "cert");
			string keyPem = Pem.Tag(text, "key");
			try { o.caCert = Pem.CertFromPem(caPem != null ? caPem : text); } catch { }
			if (o.caCert == null) { err = "OpenVPN config missing <ca>"; return false; }
			RSACryptoServiceProvider rsa = null;
			try { rsa = Pem.RsaFromPem(keyPem != null ? keyPem : text); } catch (Exception ex) { err = "client key: " + ex.Message; return false; }
			byte[] certDer = certPem != null ? Pem.Block(certPem, "CERTIFICATE") : null;
			if (certDer == null) certDer = ExtractNthCertDer(text, 1);
			try { o.clCert = Pem.CertWithKey(certDer, rsa); } catch (Exception ex) { err = "client cert: " + ex.Message; return false; }
			if (o.clCert == null || rsa == null) { err = "OpenVPN config missing <cert> and <key>"; return false; }
			o.RemoteHost = host;
			o.RemotePort = port > 0 ? port : 1194;
			s = o; return true;
		}
		static byte[] ExtractNthCertDer(string text, int skip) {
			int from = 0; int seen = 0;
			while (true) {
				int i = text.IndexOf("-----BEGIN CERTIFICATE-----", from, StringComparison.Ordinal);
				if (i < 0) return null;
				int j = text.IndexOf("-----END CERTIFICATE-----", i, StringComparison.Ordinal);
				if (j < 0) return null;
				j += "-----END CERTIFICATE-----".Length;
				if (seen == skip) return Pem.Block(text.Substring(i, j - i), "CERTIFICATE");
				seen++; from = j;
			}
		}
		public bool Resolve(out string err) {
			err = "";
			IPAddress ip = null;
			if (!IPAddress.TryParse(RemoteHost, out ip)) {
				try {
					IPAddress[] addrs = Dns.GetHostAddresses(RemoteHost);
					for (int i = 0; i < addrs.Length; i++)
						if (addrs[i].AddressFamily == AddressFamily.InterNetwork) { ip = addrs[i]; break; }
				} catch (Exception ex) { err = "OpenVPN remote DNS failed: " + ex.Message; return false; }
			}
			if (ip == null || ip.AddressFamily != AddressFamily.InterNetwork) {
				err = "OpenVPN remote DNS failed: " + RemoteHost; return false;
			}
			Endpoint = new IPEndPoint(ip, RemotePort);
			return true;
		}

		void KeysFromStatic() {
			encKe = new byte[32]; encKa = new byte[32]; decKe = new byte[32]; decKa = new byte[32];
			Buffer.BlockCopy(TlsCryptKey, 128, encKe, 0, 32);
			Buffer.BlockCopy(TlsCryptKey, 192, encKa, 0, 32);
			Buffer.BlockCopy(TlsCryptKey, 0, decKe, 0, 32);
			Buffer.BlockCopy(TlsCryptKey, 64, decKa, 0, 32);
		}
		static void Be32(byte[] d, int o, uint v) {
			d[o] = (byte)(v >> 24); d[o + 1] = (byte)(v >> 16); d[o + 2] = (byte)(v >> 8); d[o + 3] = (byte)v;
		}
		static uint Rb32(byte[] d, int o) {
			return ((uint)d[o] << 24) | ((uint)d[o + 1] << 16) | ((uint)d[o + 2] << 8) | d[o + 3];
		}
		byte[] Wrap(byte opcode, byte[] plain) {
			byte[] hdr = new byte[17];
			hdr[0] = opcode;
			Buffer.BlockCopy(locSid, 0, hdr, 1, 8);
			uint pid; uint ts;
			lock (gate) { pid = wrapPid++; ts = (uint)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds; }
			Be32(hdr, 9, pid); Be32(hdr, 13, ts);
			byte[] macIn = new byte[17 + plain.Length];
			Buffer.BlockCopy(hdr, 0, macIn, 0, 17);
			Buffer.BlockCopy(plain, 0, macIn, 17, plain.Length);
			byte[] tag;
			using (HMACSHA256 h = new HMACSHA256(encKa)) tag = h.ComputeHash(macIn);
			byte[] iv = new byte[16]; Buffer.BlockCopy(tag, 0, iv, 0, 16);
			byte[] ct = AesGcmPt.CtrCrypt(encKe, iv, plain);
			byte[] o = new byte[17 + 32 + ct.Length];
			Buffer.BlockCopy(hdr, 0, o, 0, 17);
			Buffer.BlockCopy(tag, 0, o, 17, 32);
			Buffer.BlockCopy(ct, 0, o, 49, ct.Length);
			return o;
		}
		byte[] Unwrap(byte[] pkt) {
			if (pkt == null || pkt.Length < 49) return null;
			byte[] ct = new byte[pkt.Length - 49];
			Buffer.BlockCopy(pkt, 49, ct, 0, ct.Length);
			byte[] iv = new byte[16]; Buffer.BlockCopy(pkt, 17, iv, 0, 16);
			byte[] plain = AesGcmPt.CtrCrypt(decKe, iv, ct);
			byte[] macIn = new byte[17 + plain.Length];
			Buffer.BlockCopy(pkt, 0, macIn, 0, 17);
			Buffer.BlockCopy(plain, 0, macIn, 17, plain.Length);
			byte[] want;
			using (HMACSHA256 h = new HMACSHA256(decKa)) want = h.ComputeHash(macIn);
			int diff = 0;
			for (int i = 0; i < 32; i++) diff |= want[i] ^ pkt[17 + i];
			if (diff != 0) return null;
			return plain;
		}
		byte[] CtrlPlain(int opcode, uint thisPid, byte[] tls) {
			MemoryStream ms = new MemoryStream();
			lock (gate) {
				int n = pendingAck.Count; if (n > 4) n = 4;
				ms.WriteByte((byte)n);
				for (int i = 0; i < n; i++) {
					byte[] b = new byte[4]; Be32(b, 0, pendingAck[i]); ms.Write(b, 0, 4);
				}
				if (n > 0) ms.Write(remSid, 0, 8);
				if (n > 0) pendingAck.RemoveRange(0, n);
			}
			if (opcode != 5) {
				byte[] pid = new byte[4]; Be32(pid, 0, thisPid); ms.Write(pid, 0, 4);
				if (tls != null && tls.Length > 0) ms.Write(tls, 0, tls.Length);
			}
			return ms.ToArray();
		}
		void SendCtrl(int opcode, uint thisPid, byte[] tls) {
			byte op = (byte)(opcode << 3);
			byte[] plain = CtrlPlain(opcode, thisPid, tls);
			byte[] wire = Wrap(op, plain);
			if (opcode != 5) {
				lock (gate) {
					sendTls[thisPid] = tls == null ? new byte[0] : tls;
					sendAt[thisPid] = DateTime.UtcNow;
					sendOp[thisPid] = opcode;
				}
			}
			VpnHub.UdpSendRaw(wire);
		}
		void SendTls(byte[] tls) {
			if (tls == null || tls.Length == 0) return;
			int off = 0;
			while (off < tls.Length) {
				int n = tls.Length - off; if (n > 1150) n = 1150;
				byte[] chunk = new byte[n];
				Buffer.BlockCopy(tls, off, chunk, 0, n);
				uint pid;
				lock (gate) { pid = msgPid++; }
				SendCtrl(4, pid, chunk);
				off += n;
			}
		}
		public bool StartHs() {
			KeysFromStatic();
			new RNGCryptoServiceProvider().GetBytes(locSid);
			ctl.OnWrite = SendTls;
			SendCtrl(7, 0, null);
			Thread t = new Thread(Hs); t.IsBackground = true; t.Name = "pt-ovpn-hs"; t.Start();
			return true;
		}
		bool WaitSid(int ms) {
			DateTime d = DateTime.UtcNow.AddMilliseconds(ms);
			while (DateTime.UtcNow < d) {
				lock (gate) {
					bool ok = false;
					for (int i = 0; i < 8; i++) if (remSid[i] != 0) { ok = true; break; }
					if (ok) return true;
				}
				if (ctl.dead) return false;
				Thread.Sleep(50);
			}
			return false;
		}
		void Hs() {
			try {
				if (!WaitSid(15000)) { VpnHub.LastError = "OpenVPN no server reset"; return; }
				X509CertificateCollection cc = new X509CertificateCollection();
				if (clCert != null) cc.Add(clCert);
				ssl = new SslStream(ctl, false, Validate);
				ssl.AuthenticateAsClient(RemoteHost, cc, SslProtocols.Tls12, false);
				byte[] km = BuildKm2();
				ssl.Write(km, 0, km.Length);
				byte[] their = ReadKm2();
				if (their == null) { VpnHub.LastError = "OpenVPN no server keys"; return; }
				Derive();
				byte[] push = Encoding.ASCII.GetBytes("PUSH_REQUEST");
				byte[] pr = new byte[push.Length + 1]; Buffer.BlockCopy(push, 0, pr, 0, push.Length);
				ssl.Write(pr, 0, pr.Length);
				if (!ReadPush()) {
					if (string.IsNullOrEmpty(VpnHub.LastError)) VpnHub.LastError = "OpenVPN no PUSH_REPLY";
					return;
				}
				if (CipherName.IndexOf("AES-256-GCM", StringComparison.OrdinalIgnoreCase) < 0) {
					VpnHub.LastError = "OpenVPN data cipher " + CipherName + " is not supported.";
					return;
				}
				keysUp = true;
				VpnHub.NoteOvpnUp();
			} catch (Exception ex) { VpnHub.LastError = "OpenVPN TLS: " + ex.Message; ctl.dead = true; }
		}
		bool Validate(object sender, X509Certificate cert, X509Chain chain, SslPolicyErrors e) {
			if (caCert == null || cert == null) return false;
			try {
				X509Certificate2 c2 = cert as X509Certificate2;
				if (c2 == null) c2 = new X509Certificate2(cert);
				X509Chain ch = new X509Chain();
				ch.ChainPolicy.ExtraStore.Add(caCert);
				ch.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
				ch.ChainPolicy.VerificationFlags = X509VerificationFlags.AllowUnknownCertificateAuthority;
				ch.Build(c2);
				for (int i = 0; i < ch.ChainElements.Count; i++) {
					if (string.Equals(ch.ChainElements[i].Certificate.Thumbprint, caCert.Thumbprint, StringComparison.OrdinalIgnoreCase)) return true;
				}
				return string.Equals(c2.Issuer, caCert.Subject, StringComparison.Ordinal);
			} catch { return false; }
		}
		byte[] BuildKm2() {
			byte[] src = new byte[112];
			new RNGCryptoServiceProvider().GetBytes(src);
			lock (gate) { kmClient = src; }
			string opt = "V4,dev-type tun,link-mtu 1569,tun-mtu 1500,proto UDPv4,cipher AES-256-GCM,auth SHA512,keysize 256,key-method 2,tls-client";
			string pi = "IV_VER=2.6.12\nIV_PLAT=win\nIV_NCP=2\nIV_TCPNL=1\nIV_PROTO=22\nIV_CIPHERS=AES-256-GCM\nIV_LZO_STUB=1\nIV_COMP_STUB=1\n";
			MemoryStream ms = new MemoryStream();
			ms.Write(new byte[4], 0, 4);
			ms.WriteByte(2);
			ms.Write(src, 0, 112);
			WriteOvStr(ms, opt);
			WriteOvStr(ms, User);
			WriteOvStr(ms, Pass);
			WriteOvStr(ms, pi);
			return ms.ToArray();
		}
		static void WriteOvStr(MemoryStream ms, string s) {
			if (s == null) s = "";
			byte[] b = Encoding.ASCII.GetBytes(s);
			byte[] n = new byte[2]; n[0] = (byte)((b.Length + 1) >> 8); n[1] = (byte)(b.Length + 1);
			ms.Write(n, 0, 2); ms.Write(b, 0, b.Length); ms.WriteByte(0);
		}
		byte[] ReadExactSsl(int n) {
			byte[] b = new byte[n]; int g = 0;
			DateTime d = DateTime.UtcNow.AddSeconds(25);
			while (g < n) {
				if (DateTime.UtcNow > d) return null;
				int r = ssl.Read(b, g, n - g);
				if (r <= 0) return null;
				g += r;
			}
			return b;
		}
		byte[] ReadKm2() {
			byte[] hdr = ReadExactSsl(5);
			if (hdr == null || hdr[4] != 2) return null;
			byte[] src = ReadExactSsl(64);
			if (src == null) return null;
			kmServer = src;
			SkipOvStr(); SkipOvStr(); SkipOvStr(); SkipOvStr();
			return src;
		}
		void SkipOvStr() {
			byte[] n = ReadExactSsl(2); if (n == null) return;
			int len = (n[0] << 8) | n[1];
			if (len > 0 && len < 4096) ReadExactSsl(len);
		}
		bool ReadPush() {
			DateTime d = DateTime.UtcNow.AddSeconds(20);
			MemoryStream ms = new MemoryStream();
			byte[] buf = new byte[2048];
			while (DateTime.UtcNow < d) {
				int r;
				try { r = ssl.Read(buf, 0, buf.Length); } catch { return false; }
				if (r <= 0) return false;
				ms.Write(buf, 0, r);
				byte[] all = ms.ToArray();
				int start = 0;
				for (int i = 0; i < all.Length; i++) {
					if (all[i] != 0) continue;
					string cmd = Encoding.ASCII.GetString(all, start, i - start);
					start = i + 1;
					if (cmd.StartsWith("PUSH_REPLY", StringComparison.Ordinal)) {
						ApplyPush(cmd);
						return true;
					}
					if (cmd.StartsWith("AUTH_FAILED", StringComparison.Ordinal)) {
						VpnHub.LastError = cmd; return false;
					}
				}
			}
			return false;
		}
		void ApplyPush(string cmd) {
			string[] parts = cmd.Split(',');
			for (int i = 0; i < parts.Length; i++) {
				string p = parts[i].Trim();
				if (p.StartsWith("ifconfig ", StringComparison.Ordinal)) {
					string[] a = p.Split(' ');
					if (a.Length >= 2) {
						try { VpnHub.SetTunnelIp(IPAddress.Parse(a[1])); } catch { }
					}
				} else if (p.StartsWith("dhcp-option DNS ", StringComparison.OrdinalIgnoreCase) || p.StartsWith("dhcp-option dns ", StringComparison.OrdinalIgnoreCase)) {
					string[] a = p.Split(' ');
					if (a.Length >= 3) { try { VpnHub.SetDnsIp(IPAddress.Parse(a[2])); } catch { } }
				} else if (p.StartsWith("peer-id ", StringComparison.Ordinal)) {
					int.TryParse(p.Substring(8).Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out peerId);
				} else if (p.StartsWith("cipher ", StringComparison.Ordinal)) {
					CipherName = p.Substring(7).Trim().ToUpperInvariant();
				} else if (p.StartsWith("ping ", StringComparison.Ordinal)) {
					int ka; if (int.TryParse(p.Substring(5).Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out ka) && ka > 0)
						VpnHub.SetKeepalive(ka);
				}
			}
		}
		void Derive() {
			byte[] pre = new byte[48]; Buffer.BlockCopy(kmClient, 0, pre, 0, 48);
			byte[] cr1 = new byte[32]; Buffer.BlockCopy(kmClient, 48, cr1, 0, 32);
			byte[] cr2 = new byte[32]; Buffer.BlockCopy(kmClient, 80, cr2, 0, 32);
			byte[] sr1 = new byte[32]; Buffer.BlockCopy(kmServer, 0, sr1, 0, 32);
			byte[] sr2 = new byte[32]; Buffer.BlockCopy(kmServer, 32, sr2, 0, 32);
			byte[] seed1 = Cat(cr1, sr1);
			byte[] master = Tls1Prf.Prf(pre, "OpenVPN master secret", seed1, 48);
			byte[] seed2 = new byte[32 + 32 + 8 + 8];
			Buffer.BlockCopy(cr2, 0, seed2, 0, 32);
			Buffer.BlockCopy(sr2, 0, seed2, 32, 32);
			Buffer.BlockCopy(locSid, 0, seed2, 64, 8);
			Buffer.BlockCopy(remSid, 0, seed2, 72, 8);
			byte[] kb = Tls1Prf.Prf(master, "OpenVPN key expansion", seed2, 256);
			sendCk = new byte[32]; recvCk = new byte[32]; sendIv = new byte[8]; recvIv = new byte[8];
			Buffer.BlockCopy(kb, 0, sendCk, 0, 32);
			Buffer.BlockCopy(kb, 64, sendIv, 0, 8);
			Buffer.BlockCopy(kb, 128, recvCk, 0, 32);
			Buffer.BlockCopy(kb, 192, recvIv, 0, 8);
		}
		static byte[] Cat(byte[] a, byte[] b) {
			byte[] c = new byte[a.Length + b.Length]; Buffer.BlockCopy(a, 0, c, 0, a.Length); Buffer.BlockCopy(b, 0, c, a.Length, b.Length); return c;
		}
		public void OnPacket(byte[] pkt) {
			if (pkt == null || pkt.Length < 1) return;
			int op = pkt[0] >> 3;
			if (op == 6 || op == 9) { OnData(pkt, op); return; }
			byte[] plain = Unwrap(pkt);
			if (plain == null) return;
			VpnHub.NoteRx();
			lock (gate) { Buffer.BlockCopy(pkt, 1, remSid, 0, 8); }
			int o = 0;
			if (o >= plain.Length) return;
			int nack = plain[o++];
			for (int i = 0; i < nack; i++) {
				if (o + 4 > plain.Length) return;
				uint aid = Rb32(plain, o); o += 4;
				lock (gate) { sendTls.Remove(aid); sendAt.Remove(aid); sendOp.Remove(aid); }
			}
			if (nack > 0) {
				if (o + 8 > plain.Length) return;
				o += 8;
			}
			if (op == 5) return;
			if (o + 4 > plain.Length) return;
			uint pid = Rb32(plain, o); o += 4;
			lock (gate) { pendingAck.Add(pid); }
			byte[] tls = null;
			if (o < plain.Length) {
				tls = new byte[plain.Length - o];
				Buffer.BlockCopy(plain, o, tls, 0, tls.Length);
			}
			lock (gate) {
				if (pid == nextIn) {
					if (tls != null && tls.Length > 0) ctl.Push(tls, 0, tls.Length);
					nextIn++;
					byte[] more;
					while (ooo.TryGetValue(nextIn, out more)) {
						ooo.Remove(nextIn);
						if (more != null && more.Length > 0) ctl.Push(more, 0, more.Length);
						nextIn++;
					}
				} else if (pid > nextIn && ooo.Count < 32 && !ooo.ContainsKey(pid)) ooo[pid] = tls;
			}
			SendCtrl(5, 0, null);
		}
		void OnData(byte[] pkt, int op) {
			if (!keysUp || recvCk == null) return;
			int hdr = op == 9 ? 4 : 1;
			if (pkt.Length < hdr + 4 + 16) return;
			uint pid = Rb32(pkt, hdr);
			byte[] nonce = new byte[12];
			Be32(nonce, 0, pid);
			Buffer.BlockCopy(recvIv, 0, nonce, 4, 8);
			byte[] ad = new byte[hdr + 4];
			Buffer.BlockCopy(pkt, 0, ad, 0, hdr + 4);
			int tagOff = hdr + 4;
			int ctLen = pkt.Length - tagOff - 16;
			if (ctLen < 0) return;
			byte[] ctTag = new byte[ctLen + 16];
			Buffer.BlockCopy(pkt, tagOff + 16, ctTag, 0, ctLen);
			Buffer.BlockCopy(pkt, tagOff, ctTag, ctLen, 16);
			byte[] inner = AesGcmPt.Open(recvCk, nonce, ad, ctTag);
			if (inner == null) return;
			VpnHub.NoteRx();
			if (inner.Length == 16) {
				int same = 0;
				for (int i = 0; i < 16; i++) if (inner[i] == PingMagic[i]) same++;
				if (same == 16) return;
			}
			VpnHub.OnInnerIp(inner);
		}
		public void SendInner(byte[] inner) {
			if (!keysUp || sendCk == null) return;
			uint pid;
			lock (gate) { pid = dataPid++; }
			byte[] nonce = new byte[12];
			Be32(nonce, 0, pid);
			Buffer.BlockCopy(sendIv, 0, nonce, 4, 8);
			byte[] hdr = new byte[4];
			hdr[0] = (byte)(9 << 3);
			hdr[1] = (byte)((peerId >> 16) & 255);
			hdr[2] = (byte)((peerId >> 8) & 255);
			hdr[3] = (byte)(peerId & 255);
			byte[] ad = new byte[8];
			Buffer.BlockCopy(hdr, 0, ad, 0, 4);
			Be32(ad, 4, pid);
			byte[] sealedB = AesGcmPt.Seal(sendCk, nonce, ad, inner);
			byte[] pkt = new byte[8 + sealedB.Length];
			Buffer.BlockCopy(hdr, 0, pkt, 0, 4);
			Be32(pkt, 4, pid);
			Buffer.BlockCopy(sealedB, sealedB.Length - 16, pkt, 8, 16);
			Buffer.BlockCopy(sealedB, 0, pkt, 24, sealedB.Length - 16);
			VpnHub.UdpSendRaw(pkt);
		}
		public void SendPing() {
			if (!keysUp) return;
			SendInner(PingMagic);
		}
		public void Tick() {
			DateTime now = DateTime.UtcNow;
			List<uint> retry = new List<uint>();
			lock (gate) {
				foreach (KeyValuePair<uint, DateTime> kv in sendAt) {
					if ((now - kv.Value).TotalMilliseconds >= 1000) retry.Add(kv.Key);
				}
			}
			for (int i = 0; i < retry.Count; i++) {
				uint id = retry[i];
				int opcode; byte[] tls;
				lock (gate) {
					if (!sendTls.ContainsKey(id) || !sendOp.ContainsKey(id)) continue;
					opcode = sendOp[id]; tls = sendTls[id];
				}
				SendCtrl(opcode, id, tls);
			}
			bool needAck;
			lock (gate) needAck = pendingAck.Count > 0;
			if (needAck) SendCtrl(5, 0, null);
		}
		public void Close() {
			ctl.dead = true;
			try { ctl.ev.Set(); } catch { }
			try { if (ssl != null) ssl.Close(); } catch { }
		}
	}

	public static class VpnHub {
		public static bool Require;
		public static string LastError = "";
		public static string Status = "off";
		public static string ProvenIp = "";
		public static bool ProbeDone;
		public static string EndpointHost {
			get { return endpoint == null ? "" : endpoint.ToString(); }
		}
		static int vpnKind;
		static string ovpnRaw;
		static OvpnSess ovpn;
		static byte[] priv, peerPub, psk;
		static uint localIp, dnsIp;
		static IPEndPoint endpoint;
		static int keepalive = 15, mtu = 1320;
		static UdpClient udp;
		static Thread thr;
		static volatile bool run, up;
		static byte[] sendKey, recvKey;
		static uint localIndex, remoteIndex, hsLocalIndex;
		static ulong sendCtr, recvCtr;
		static DateTime lastHs = DateTime.MinValue, lastHsOk = DateTime.MinValue, lastData = DateTime.MinValue, lastRecv = DateTime.MinValue;
		static byte[] hsCk, hsHash, ephPriv, ephPub, staticPub;
		static readonly object gate = new object();
		static readonly object udpGate = new object();
		static readonly Dictionary<string, VpnTcp> tcps = new Dictionary<string, VpnTcp>();
		static readonly Dictionary<int, VpnUdpSock> udps = new Dictionary<int, VpnUdpSock>();
		static readonly Queue<VpnTcp> accepts = new Queue<VpnTcp>();
		static readonly AutoResetEvent acceptEv = new AutoResetEvent(false);
		static int listenPort = -1;
		static ushort nextEph = 40000;
		static uint ipId;
		static int loopTicks;
		public static bool TunnelOn { get { return up; } }
		public static bool HasConfig { get { return vpnKind != 0; } }
		public static string Kind { get { return vpnKind == 2 ? "OpenVPN" : (vpnKind == 1 ? "WireGuard" : ""); } }
		public static bool Blocked { get { return HasConfig && !up; } }
		public static int Mtu { get { return mtu; } }
		public static string LocalAddress {
			get { return localIp == 0 ? "" : string.Format(CultureInfo.InvariantCulture, "{0}.{1}.{2}.{3}", (localIp >> 24) & 255, (localIp >> 16) & 255, (localIp >> 8) & 255, localIp & 255); }
		}

		static byte[] Hx(string s) {
			byte[] o = new byte[s.Length / 2];
			for (int i = 0; i < o.Length; i++)
				o[i] = byte.Parse(s.Substring(i * 2, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture);
			return o;
		}

		public static string SelfCheck() {
			byte[] z = Blake2s.Hash(new byte[0], 32);
			string hex = BitConverter.ToString(z).Replace("-", "").ToLowerInvariant();
			if (hex != "69217a3079908094e11121d042354a7c1f55b6482ca1a51e1b250dfd1ed0eef9") return "blake2s " + hex;
			byte[] abc = Blake2s.Hash(Encoding.ASCII.GetBytes("abc"), 32);
			string abch = BitConverter.ToString(abc).Replace("-", "").ToLowerInvariant();
			if (abch != "508c5e8c327c14e2e1a72ba34eeb452f37458b209ed63a294d999b4c86675982") return "blake2s-abc " + abch;
			byte[] sk = Hx("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4");
			byte[] su = Hx("e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c");
			byte[] so = X25519.ScalarMult(sk, su);
			string soh = BitConverter.ToString(so).Replace("-", "").ToLowerInvariant();
			if (soh != "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552") return "x25519 " + soh;
			byte[] k = new byte[32];
			for (int i = 0; i < 32; i++) k[i] = (byte)i;
			byte[] pt = Encoding.ASCII.GetBytes("powertorrent-aead");
			byte[] sealedB = ChaChaPoly.Seal(k, 7, pt, Encoding.ASCII.GetBytes("ad"));
			byte[] open = ChaChaPoly.Open(k, 7, sealedB, Encoding.ASCII.GetBytes("ad"));
			if (open == null || open.Length != pt.Length) return "aead-open";
			for (int i = 0; i < pt.Length; i++) if (open[i] != pt[i]) return "aead-pt";
			if (ChaChaPoly.Open(k, 8, sealedB, Encoding.ASCII.GetBytes("ad")) != null) return "aead-ctr";
			byte[] rfcKey = Hx("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f");
			byte[] rfcNonce = Hx("070000004041424344454647");
			byte[] rfcAad = Hx("50515253c0c1c2c3c4c5c6c7");
			byte[] rfcPt = Hx("4c616469657320616e642047656e746c656d656e206f662074686520636c617373206f66202739393a204966204920636f756c64206f6666657220796f75206f6e6c79206f6e652074697020666f7220746865206675747572652c2073756e73637265656e20776f756c642062652069742e");
			byte[] rfcWant = Hx("d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d63dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b3692ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc3ff4def08e4b7a9de576d26586cec64b61161ae10b594f09e26a7e902ecbd0600691");
			byte[] rfcGot = ChaChaPoly.SealNonce(rfcKey, rfcNonce, rfcPt, rfcAad);
			if (rfcGot == null || rfcGot.Length != rfcWant.Length) return "aead-rfc-len";
			for (int i = 0; i < rfcWant.Length; i++) if (rfcGot[i] != rfcWant[i]) return "aead-rfc " + i.ToString(CultureInfo.InvariantCulture);
			byte[] prf = Tls1Prf.Prf(Encoding.ASCII.GetBytes("tls1-prf-test-secret"), "tls1-prf-test", new byte[0], 8);
			byte[] wantPrf = new byte[] { 0x71, 0x44, 0xfe, 0x25, 0x40, 0x73, 0x75, 0x95 };
			if (prf == null || prf.Length != 8) return "tls1-prf-len";
			for (int i = 0; i < 8; i++) if (prf[i] != wantPrf[i]) return "tls1-prf";
			byte[] gk = new byte[32];
			byte[] gn = new byte[12];
			byte[] gcm = AesGcmPt.Seal(gk, gn, new byte[0], new byte[0]);
			byte[] gwant = Hx("530f8afbc74536b9a963b4f1c4cb738b");
			if (gcm == null || gcm.Length != 16) return "gcm-len";
			for (int i = 0; i < 16; i++) if (gcm[i] != gwant[i]) return "gcm-empty";
			byte[] gopen = AesGcmPt.Open(gk, gn, new byte[0], gcm);
			if (gopen == null || gopen.Length != 0) return "gcm-open-empty";
			byte[] gpt = Encoding.ASCII.GetBytes("powertorrent-gcm");
			byte[] gad = Encoding.ASCII.GetBytes("ad");
			byte[] gse = AesGcmPt.Seal(gk, gn, gad, gpt);
			byte[] gop = AesGcmPt.Open(gk, gn, gad, gse);
			if (gop == null || gop.Length != gpt.Length) return "gcm-rt";
			for (int i = 0; i < gpt.Length; i++) if (gop[i] != gpt[i]) return "gcm-pt";
			if (AesGcmPt.Open(gk, gn, Encoding.ASCII.GetBytes("xx"), gse) != null) return "gcm-ad";
			return null;
		}

		public static bool LoadConfig(string text, out string err) {
			err = "";
			if (string.IsNullOrEmpty(text)) { err = "empty config"; return false; }
			if (text.IndexOf("[Interface]", StringComparison.OrdinalIgnoreCase) >= 0)
				return LoadWireGuard(text, out err);
			OvpnSess parsed;
			if (OvpnSess.TryParse(text, out parsed, out err)) {
				Stop();
				if (!parsed.Resolve(out err)) err = "";
				lock (gate) {
					vpnKind = 2; ovpnRaw = text; ovpn = parsed;
					Require = true;
					priv = null; peerPub = null; psk = null; staticPub = null;
					endpoint = parsed.Endpoint;
					localIp = 0; dnsIp = 0;
					keepalive = 10; mtu = parsed.TunMtu > 576 ? Math.Min(parsed.TunMtu, 1400) : 1400;
				}
				Status = "configured OpenVPN " + parsed.RemoteHost;
				LastError = "";
				return true;
			}
			if (string.IsNullOrEmpty(err) || err == "not an OpenVPN config")
				err = "not a WireGuard or OpenVPN config";
			return false;
		}

		static bool LoadWireGuard(string text, out string err) {
			err = "";
			try {
				string privB = null, pubB = null, pskB = null, addr = null, ep = null, dns = null;
				int ka = 15, m = 1320;
				string[] lines = text.Replace("\r", "").Split('\n');
				for (int i = 0; i < lines.Length; i++) {
					string ln = lines[i].Trim();
					if (ln.Length == 0 || ln[0] == '#' || ln[0] == ';') continue;
					int eq = ln.IndexOf('='); if (eq < 1) continue;
					string k = ln.Substring(0, eq).Trim().ToLowerInvariant();
					string v = ln.Substring(eq + 1).Trim();
					if (k == "privatekey") privB = v;
					else if (k == "publickey") pubB = v;
					else if (k == "presharedkey") pskB = v;
					else if (k == "address") addr = v.Split(',')[0].Trim();
					else if (k == "endpoint") ep = v;
					else if (k == "dns") dns = v.Split(',')[0].Trim();
					else if (k == "mtu") int.TryParse(v, NumberStyles.Integer, CultureInfo.InvariantCulture, out m);
					else if (k == "persistentkeepalive") int.TryParse(v, NumberStyles.Integer, CultureInfo.InvariantCulture, out ka);
				}
				if (string.IsNullOrEmpty(privB) || string.IsNullOrEmpty(pubB) || string.IsNullOrEmpty(ep) || string.IsNullOrEmpty(addr)) {
					err = "config missing PrivateKey, PublicKey, Endpoint, or Address"; return false;
				}
				byte[] np = Convert.FromBase64String(privB);
				byte[] npp = Convert.FromBase64String(pubB);
				if (np.Length != 32 || npp.Length != 32) { err = "keys must be 32 bytes"; return false; }
				byte[] npsk = new byte[32];
				if (!string.IsNullOrEmpty(pskB)) {
					byte[] p = Convert.FromBase64String(pskB);
					if (p.Length != 32) { err = "PresharedKey must be 32 bytes"; return false; }
					npsk = p;
				}
				int slash = addr.IndexOf('/'); if (slash > 0) addr = addr.Substring(0, slash);
				uint nip = IpToU(IPAddress.Parse(addr));
				uint ndns = 0;
				if (!string.IsNullOrEmpty(dns)) { try { ndns = IpToU(IPAddress.Parse(dns.Split(' ')[0])); } catch { } }
				int c = ep.LastIndexOf(':');
				if (c < 1) { err = "Endpoint must be ip:port"; return false; }
				IPEndPoint nep = new IPEndPoint(IPAddress.Parse(ep.Substring(0, c)), int.Parse(ep.Substring(c + 1), CultureInfo.InvariantCulture));
				lock (gate) {
					vpnKind = 1; ovpnRaw = null; ovpn = null;
					Require = true;
					priv = np; peerPub = npp; psk = npsk;
					staticPub = X25519.PublicFromPrivate(priv);
					localIp = nip; dnsIp = ndns; endpoint = nep;
					keepalive = ka < 1 ? 15 : ka; mtu = m < 576 ? 1320 : m;
				}
				Status = "configured " + addr; LastError = "";
				return true;
			} catch (Exception ex) { err = ex.Message; return false; }
		}

		public static void ClearConfig() {
			Stop();
			lock (gate) {
				vpnKind = 0; ovpnRaw = null; ovpn = null;
				priv = null; peerPub = null; psk = null; staticPub = null; endpoint = null; localIp = 0; dnsIp = 0;
			}
			Status = "off"; LastError = "";
		}

		public static bool BeginStart() {
			if (vpnKind == 0) { LastError = "no VPN config"; Status = "off"; return false; }
			StopCore(false);
			try {
				if (vpnKind == 2) {
					OvpnSess parsed;
					string e;
					if (!OvpnSess.TryParse(ovpnRaw, out parsed, out e)) { LastError = e; Status = "error"; return false; }
					if (!parsed.Resolve(out e)) { LastError = e; Status = "error"; return false; }
					ovpn = parsed; endpoint = parsed.Endpoint;
				}
				udp = new UdpClient(0, AddressFamily.InterNetwork);
				udp.Client.ReceiveTimeout = 200;
				run = true; up = false;
				Status = "connecting"; LastError = "";
				if (vpnKind == 2) {
					thr = new Thread(LoopOvpn); thr.IsBackground = true; thr.Name = "pt-ovpn"; thr.Start();
				} else {
					thr = new Thread(Loop); thr.IsBackground = true; thr.Name = "pt-wg"; thr.Start();
				}
				return true;
			} catch (Exception ex) { LastError = ex.Message; Status = "error"; StopCore(true); return false; }
		}

		public static bool Start() {
			if (!BeginStart()) return false;
			int wait = vpnKind == 2 ? 40 : 25;
			DateTime dead = DateTime.UtcNow.AddSeconds(wait);
			while (!up && DateTime.UtcNow < dead) Thread.Sleep(50);
			if (!up) {
				if (string.IsNullOrEmpty(LastError)) LastError = "handshake timeout to " + endpoint;
				StopCore(true); return false;
			}
			Status = "up " + LocalAddress + " via " + endpoint; LastError = "";
			try { Session.RebindListen(); } catch { }
			return true;
		}

		public static void Stop() { StopCore(true); }

		static void StopCore(bool rebind) {
			run = false; up = false;
			lastHsOk = DateTime.MinValue;
			Interlocked.Increment(ref probeGen);
			ProvenIp = "";
			ProbeDone = false;
			try { if (ovpn != null) ovpn.Close(); } catch { }
			try { if (udp != null) udp.Close(); } catch { }
			udp = null;
			lock (gate) {
				foreach (VpnTcp t in new List<VpnTcp>(tcps.Values)) { t.state = 0; t.ev.Set(); }
				tcps.Clear(); udps.Clear(); accepts.Clear();
				sendKey = null; recvKey = null;
			}
			Status = HasConfig ? "configured" : "off";
			if (rebind) { try { Session.RebindListen(); } catch { } }
		}

		public static IPAddress Resolve(string host) {
			if (!up) return null;
			if (dnsIp == 0) return null;
			VpnUdpSock s = null;
			try {
				Random rng = new Random();
				ushort id = (ushort)rng.Next(1, 65535);
				MemoryStream ms = new MemoryStream();
				ms.WriteByte((byte)(id >> 8)); ms.WriteByte((byte)id);
				ms.WriteByte(1); ms.WriteByte(0); ms.WriteByte(0); ms.WriteByte(1);
				ms.WriteByte(0); ms.WriteByte(0); ms.WriteByte(0); ms.WriteByte(0); ms.WriteByte(0); ms.WriteByte(0);
				string[] lab = host.Split('.');
				for (int i = 0; i < lab.Length; i++) {
					byte[] b = Encoding.ASCII.GetBytes(lab[i]);
					ms.WriteByte((byte)b.Length); ms.Write(b, 0, b.Length);
				}
				ms.WriteByte(0); ms.WriteByte(0); ms.WriteByte(1); ms.WriteByte(0); ms.WriteByte(1);
				byte[] q = ms.ToArray();
				s = BindUdp(0);
				s.SendTo(q, new IPEndPoint(UToIp(dnsIp), 53));
				byte[] ans; IPEndPoint from;
				if (!s.Recv(4000, out ans, out from) || ans == null || ans.Length < 12) return null;
				if (((ans[0] << 8) | ans[1]) != id) return null;
				int qd = (ans[4] << 8) | ans[5], an = (ans[6] << 8) | ans[7];
				int o = 12;
				for (int i = 0; i < qd; i++) o = SkipName(ans, o) + 4;
				for (int i = 0; i < an; i++) {
					o = SkipName(ans, o);
					if (o + 10 > ans.Length) break;
					int typ = (ans[o] << 8) | ans[o + 1]; int rdlen = (ans[o + 8] << 8) | ans[o + 9]; o += 10;
					if (typ == 1 && rdlen == 4 && o + 4 <= ans.Length)
						return new IPAddress(new byte[] { ans[o], ans[o + 1], ans[o + 2], ans[o + 3] });
					o += rdlen;
				}
			} catch { }
			finally { if (s != null) DropUdp(s); }
			return null;
		}

		static int SkipName(byte[] d, int o) {
			while (o < d.Length) {
				int l = d[o];
				if (l == 0) return o + 1;
				if ((l & 0xC0) == 0xC0) return o + 2;
				o += 1 + l;
			}
			return o;
		}

		internal static VpnTcp ConnectTcp(string host, int port, int timeoutMs) {
			if (!up) return null;
			IPAddress ip = Bt.ResolveV4(host); if (ip == null) return null;
			VpnTcp t = new VpnTcp();
			t.locIp = localIp; t.remIp = IpToU(ip); t.remPort = (ushort)port;
			lock (gate) { t.locPort = nextEph++; if (nextEph < 40000) nextEph = 40000; }
			t.iss = (uint)new Random().Next(); t.sndNxt = t.iss + 1; t.sndUna = t.iss + 1; t.state = 1;
			lock (gate) tcps[Key(t.remIp, t.remPort, t.locPort)] = t;
			TcpSend(t, 0x02, null, t.iss);
			DateTime dead = DateTime.UtcNow.AddMilliseconds(timeoutMs);
			while (DateTime.UtcNow < dead && t.state != 3 && t.state != 0) t.ev.WaitOne(50);
			if (t.state != 3) { DropTcp(t); return null; }
			return t;
		}

		public static void ListenTcp(int port) { listenPort = port; }
		internal static VpnTcp AcceptTcp(int timeoutMs) {
			if (accepts.Count > 0) { lock (gate) { if (accepts.Count > 0) return accepts.Dequeue(); } }
			acceptEv.WaitOne(timeoutMs);
			lock (gate) { return accepts.Count > 0 ? accepts.Dequeue() : null; }
		}
		internal static VpnUdpSock BindUdp(int port) {
			VpnUdpSock s = new VpnUdpSock();
			lock (gate) {
				if (port == 0) { port = nextEph++; if (nextEph < 40000) nextEph = 40000; }
				s.locPort = (ushort)port; udps[port] = s;
			}
			return s;
		}
		internal static void DropUdp(VpnUdpSock s) {
			if (s == null) return;
			lock (gate) udps.Remove(s.locPort);
		}
		internal static void UdpSend(VpnUdpSock s, byte[] data, IPEndPoint ep) {
			uint dip = IpToU(ep.Address);
			byte[] pkt = BuildUdp(localIp, s.locPort, dip, (ushort)ep.Port, data);
			SendInner(pkt);
		}
		internal static void TcpSend(VpnTcp t, int flags, byte[] payload, uint seq) {
			if (payload == null) payload = new byte[0];
			byte[] pkt = BuildTcp(t.locIp, t.locPort, t.remIp, t.remPort, seq, t.rcvNxt, flags, payload);
			t.lastTx = DateTime.UtcNow; SendInner(pkt);
		}
		internal static void TcpPump(VpnTcp t) {
			if (t.state != 3) return;
			List<VpnSeg> toSend = new List<VpnSeg>();
			lock (t.gate) {
				int cap = VpnTcp.MaxFlight;
				if (t.peerWnd > 8192 && t.peerWnd < (uint)cap) cap = (int)t.peerWnd;
				int flightBytes = 0;
				for (int i = 0; i < t.flight.Count; i++) flightBytes += t.flight[i].data.Length;
				while (t.pending.Count > 0 && flightBytes < cap) {
					byte[] seg = t.pending.Dequeue();
					VpnSeg s = new VpnSeg();
					s.data = seg; s.seq = t.sndNxt; s.sent = DateTime.UtcNow;
					t.sndNxt += (uint)seg.Length;
					t.flight.Add(s);
					flightBytes += seg.Length;
					toSend.Add(s);
				}
			}
			for (int i = 0; i < toSend.Count; i++) TcpSend(t, 0x18, toSend[i].data, toSend[i].seq);
		}
		internal static void DropTcp(VpnTcp t) {
			lock (gate) tcps.Remove(Key(t.remIp, t.remPort, t.locPort));
		}

		public static bool HttpRequest(string url, int timeoutMs, long rangeStart, long rangeEnd, out int status, out byte[] body) {
			return HttpRequest(url, timeoutMs, rangeStart, rangeEnd, "PowerTorrent/1.2", out status, out body);
		}
		public static bool HttpRequest(string url, int timeoutMs, long rangeStart, long rangeEnd, string ua, out int status, out byte[] body) {
			status = 0; body = null;
			if (string.IsNullOrEmpty(ua)) ua = "PowerTorrent/1.2";
			Uri u; try { u = new Uri(url); } catch { return false; }
			int port = u.Port; if (port <= 0) port = string.Equals(u.Scheme, "https", StringComparison.OrdinalIgnoreCase) ? 443 : 80;
			VpnTcp t = ConnectTcp(u.Host, port, timeoutMs); if (t == null) return false;
			try {
				Stream raw = new VpnTcpStream(t);
				Stream s = raw;
				if (string.Equals(u.Scheme, "https", StringComparison.OrdinalIgnoreCase)) {
					SslStream ssl = new SslStream(raw, false);
					ssl.AuthenticateAsClient(u.Host, null, SslProtocols.Tls12 | SslProtocols.Tls11 | SslProtocols.Tls, false);
					s = ssl;
				}
				string path = string.IsNullOrEmpty(u.PathAndQuery) ? "/" : u.PathAndQuery;
				StringBuilder sb = new StringBuilder();
				sb.Append("GET ").Append(path).Append(" HTTP/1.0\r\nHost: ").Append(u.Host).Append("\r\nUser-Agent: ").Append(ua).Append("\r\nAccept: */*\r\nConnection: close\r\n");
				if (rangeEnd >= rangeStart && rangeStart >= 0) sb.Append("Range: bytes=").Append(rangeStart.ToString(CultureInfo.InvariantCulture)).Append("-").Append(rangeEnd.ToString(CultureInfo.InvariantCulture)).Append("\r\n");
				sb.Append("\r\n");
				byte[] req = Encoding.ASCII.GetBytes(sb.ToString());
				s.Write(req, 0, req.Length);
				MemoryStream ms = new MemoryStream();
				byte[] buf = new byte[4096];
				DateTime dead = DateTime.UtcNow.AddMilliseconds(timeoutMs);
				int hdrAt = -1;
				int contentLen = -1;
				while (DateTime.UtcNow < dead) {
					if (!t.Poll(200000)) { if (ms.Length > 0 && hdrAt >= 0 && contentLen < 0) break; continue; }
					int n = s.Read(buf, 0, buf.Length); if (n <= 0) break; ms.Write(buf, 0, n);
					if (hdrAt < 0) {
						byte[] sofar = ms.ToArray();
						string head = Encoding.ASCII.GetString(sofar);
						int sp = head.IndexOf("\r\n\r\n");
						if (sp >= 0) {
							hdrAt = sp + 4;
							int sp1 = head.IndexOf(' ');
							int sp2 = sp1 > 0 ? head.IndexOf(' ', sp1 + 1) : -1;
							if (sp1 > 0 && sp2 > sp1) int.TryParse(head.Substring(sp1 + 1, sp2 - sp1 - 1), NumberStyles.Integer, CultureInfo.InvariantCulture, out status);
							int cl = head.IndexOf("Content-Length:", StringComparison.OrdinalIgnoreCase);
							if (cl >= 0 && cl < sp) {
								int cle = head.IndexOf("\r\n", cl);
								if (cle > cl) int.TryParse(head.Substring(cl + 15, cle - (cl + 15)).Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out contentLen);
							}
						}
					}
					if (hdrAt >= 0 && contentLen >= 0 && (ms.Length - hdrAt) >= contentLen) break;
				}
				byte[] all = ms.ToArray();
				if (hdrAt < 0 || hdrAt > all.Length) return false;
				int blen = all.Length - hdrAt;
				if (contentLen >= 0 && blen > contentLen) blen = contentLen;
				body = Slice(all, hdrAt, blen);
				return true;
			} catch { return false; }
			finally { t.Close(); }
		}

		static int probeGen;
		static string ParsePlainV4(byte[] body) {
			if (body == null || body.Length == 0) return null;
			string s = Encoding.ASCII.GetString(body).Trim();
			if (s.Length == 0 || s[0] == '<') return null;
			int cut = s.Length;
			for (int i = 0; i < s.Length; i++) {
				char ch = s[i];
				if (ch == '\r' || ch == '\n' || ch == ' ' || ch == '<' || ch == ',') { cut = i; break; }
			}
			s = s.Substring(0, cut).Trim();
			IPAddress a;
			if (!IPAddress.TryParse(s, out a) || a.AddressFamily != AddressFamily.InterNetwork) return null;
			byte[] b = a.GetAddressBytes();
			int p = b[0];
			if (p == 0 || p == 10 || p == 127 || p == 169 || p >= 224) return null;
			if (p == 172 && b[1] >= 16 && b[1] <= 31) return null;
			if (p == 192 && b[1] == 168) return null;
			return a.ToString();
		}
		static string ProbeOnce() {
			if (!up) return null;
			string[] urls = new string[] {
				"https://api.ipify.org/",
				"https://icanhazip.com/",
				"https://ifconfig.me/ip",
				"https://ip.me/",
				"http://ip.me/"
			};
			string first = null;
			int agree = 0;
			for (int u = 0; u < urls.Length && up; u++) {
				int st; byte[] body;
				if (!HttpRequest(urls[u], 10000, -1, -1, "curl/8.4.0", out st, out body) || body == null) continue;
				string ip = ParsePlainV4(body);
				if (ip == null) continue;
				if (first == null) { first = ip; agree = 1; }
				else if (ip == first) { agree++; if (agree >= 2) return ip; }
			}
			return first;
		}
		static void ProbeWorker(object state) {
			int g = (int)state;
			for (int i = 0; i < 4 && up && g == probeGen; i++) {
				try {
					string ip = ProbeOnce();
					if (g != probeGen) return;
					if (ip != null) {
						ProvenIp = ip;
						ProbeDone = true;
						Status = "up " + ip + " via " + endpoint;
						return;
					}
				} catch { }
				Thread.Sleep(1500);
			}
			if (g == probeGen) ProbeDone = true;
		}
		static void BeginProbe() {
			int g = Interlocked.Increment(ref probeGen);
			ProbeDone = false;
			Thread t = new Thread(ProbeWorker);
			t.IsBackground = true;
			t.Name = "pt-ipme";
			t.Start(g);
		}

		static byte[] Slice(byte[] a, int o, int n) { byte[] b = new byte[n]; Buffer.BlockCopy(a, o, b, 0, n); return b; }
		static uint IpToU(IPAddress a) { byte[] b = a.GetAddressBytes(); return ((uint)b[0] << 24) | ((uint)b[1] << 16) | ((uint)b[2] << 8) | b[3]; }
		static IPAddress UToIp(uint u) { return new IPAddress(new byte[] { (byte)(u >> 24), (byte)(u >> 16), (byte)(u >> 8), (byte)u }); }
		static string Key(uint ip, ushort rp, ushort lp) { return ip.ToString("x") + ":" + rp.ToString(CultureInfo.InvariantCulture) + ":" + lp.ToString(CultureInfo.InvariantCulture); }

		internal static void NoteRx() { lastRecv = DateTime.UtcNow; }
		internal static void SetTunnelIp(IPAddress a) {
			if (a != null && a.AddressFamily == AddressFamily.InterNetwork) localIp = IpToU(a);
		}
		internal static void SetDnsIp(IPAddress a) {
			if (a != null && a.AddressFamily == AddressFamily.InterNetwork) dnsIp = IpToU(a);
		}
		internal static void SetKeepalive(int s) { if (s > 0) keepalive = s; }
		internal static void NoteOvpnUp() {
			if (localIp == 0) { LastError = "OpenVPN PUSH missing ifconfig"; return; }
			if (dnsIp == 0) dnsIp = 0x01010101u;
			up = true;
			lastData = DateTime.UtcNow; lastRecv = DateTime.UtcNow;
			Status = "up " + LocalAddress + " via " + endpoint; LastError = "";
			try { Session.RebindListen(); } catch { }
			BeginProbe();
		}

		static void LoopOvpn() {
			OvpnSess o = ovpn;
			if (o == null) return;
			o.StartHs();
			while (run) {
				try {
					o.Tick();
					if (up && (DateTime.UtcNow - lastRecv).TotalSeconds > 180) {
						up = false; Status = "reconnecting";
						try { Session.RebindListen(); } catch { }
					}
					if (up && keepalive > 0 && (DateTime.UtcNow - lastData).TotalSeconds >= keepalive) {
						o.SendPing(); lastData = DateTime.UtcNow;
					}
					IPEndPoint any = new IPEndPoint(IPAddress.Any, 0);
					byte[] pkt = null;
					try {
						UdpClient u = udp;
						if (u == null) break;
						pkt = u.Receive(ref any);
					} catch (SocketException) { TickTcp(); continue; }
					if (pkt == null || pkt.Length < 1) continue;
					o.OnPacket(pkt);
					if ((++loopTicks & 15) == 0) TickTcp();
				} catch { if (!run) break; }
			}
		}

		static void Loop() {
			Initiate();
			while (run) {
				try {
					DateTime now = DateTime.UtcNow;
					if (!up) {
						if (lastHs == DateTime.MinValue || (now - lastHs).TotalSeconds >= 5) Initiate();
					} else {
						if (lastHsOk != DateTime.MinValue && (now - lastHsOk).TotalSeconds >= 120 && (now - lastHs).TotalSeconds >= 5)
							Initiate();
						if (lastHsOk != DateTime.MinValue && (now - lastHsOk).TotalSeconds >= 180) {
							up = false; Status = "reconnecting";
							try { Session.RebindListen(); } catch { }
						}
					}
					if (up && keepalive > 0 && (now - lastData).TotalSeconds >= keepalive) { WgSend(new byte[0]); lastData = DateTime.UtcNow; }
					IPEndPoint any = new IPEndPoint(IPAddress.Any, 0);
					byte[] pkt = null;
					try {
						UdpClient u = udp;
						if (u == null) break;
						pkt = u.Receive(ref any);
					} catch (SocketException) { TickTcp(); continue; }
					if (pkt == null || pkt.Length < 4) continue;
					uint typ = BitConverter.ToUInt32(pkt, 0);
					if (typ == 2) HandleResp(pkt);
					else if (typ == 3) LastError = "server cookie (endpoint under load)";
					else if (typ == 4) {
						HandleData(pkt);
						if ((++loopTicks & 31) == 0) TickTcp();
					}
				} catch { if (!run) break; }
			}
		}

		static void Initiate() {
			try {
				ephPriv = X25519.RandomPrivate(); ephPub = X25519.PublicFromPrivate(ephPriv);
				byte[] idx = new byte[4]; new RNGCryptoServiceProvider().GetBytes(idx);
				hsLocalIndex = BitConverter.ToUInt32(idx, 0);
				byte[] cons = Encoding.ASCII.GetBytes("Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s");
				byte[] ident = Encoding.ASCII.GetBytes("WireGuard v1 zx2c4 Jason@zx2c4.com");
				hsCk = Blake2s.Hash(cons, 32);
				hsHash = WgKdf.HashCat(WgKdf.HashCat(hsCk, ident), peerPub);
				hsHash = WgKdf.HashCat(hsHash, ephPub);
				byte[] ck = new byte[32]; WgKdf.Kdf1(hsCk, ephPub, ck); hsCk = ck;
				byte[] key = new byte[32]; byte[] nck = new byte[32];
				WgKdf.Kdf2(hsCk, X25519.ScalarMult(ephPriv, peerPub), nck, key); hsCk = nck;
				byte[] encSt = ChaChaPoly.Seal(key, 0, staticPub, hsHash);
				hsHash = WgKdf.HashCat(hsHash, encSt);
				WgKdf.Kdf2(hsCk, X25519.ScalarMult(priv, peerPub), nck, key); hsCk = nck;
				byte[] ts = Tai();
				byte[] encTs = ChaChaPoly.Seal(key, 0, ts, hsHash);
				hsHash = WgKdf.HashCat(hsHash, encTs);
				byte[] msg = new byte[148];
				msg[0] = 1; BitConverter.GetBytes(hsLocalIndex).CopyTo(msg, 4);
				Buffer.BlockCopy(ephPub, 0, msg, 8, 32);
				Buffer.BlockCopy(encSt, 0, msg, 40, 48);
				Buffer.BlockCopy(encTs, 0, msg, 88, 28);
				byte[] mac1key = Blake2s.Hash(Cat(Encoding.ASCII.GetBytes("mac1----"), peerPub), 32);
				byte[] pre = new byte[116]; Buffer.BlockCopy(msg, 0, pre, 0, 116);
				byte[] mac1 = Blake2s.Mac16(mac1key, pre);
				Buffer.BlockCopy(mac1, 0, msg, 116, 16);
				UdpSendRaw(msg);
				lastHs = DateTime.UtcNow;
			} catch (Exception ex) { LastError = "initiate: " + ex.Message; }
		}

		static void HandleResp(byte[] pkt) {
			if (pkt.Length < 92 || hsCk == null || staticPub == null) return;
			byte[] mac1key = Blake2s.Hash(Cat(Encoding.ASCII.GetBytes("mac1----"), staticPub), 32);
			byte[] pre = new byte[60]; Buffer.BlockCopy(pkt, 0, pre, 0, 60);
			byte[] want = Blake2s.Mac16(mac1key, pre);
			for (int i = 0; i < 16; i++) if (want[i] != pkt[60 + i]) return;
			uint theirIdx = BitConverter.ToUInt32(pkt, 4);
			uint toUs = BitConverter.ToUInt32(pkt, 8);
			if (toUs != hsLocalIndex) return;
			byte[] theirEph = new byte[32]; Buffer.BlockCopy(pkt, 12, theirEph, 0, 32);
			byte[] encEmpty = new byte[16]; Buffer.BlockCopy(pkt, 44, encEmpty, 0, 16);
			byte[] hash = WgKdf.HashCat(hsHash, theirEph);
			byte[] ck = new byte[32]; WgKdf.Kdf1(hsCk, theirEph, ck);
			byte[] tmp = new byte[32];
			WgKdf.Kdf1(ck, X25519.ScalarMult(ephPriv, theirEph), tmp); ck = tmp;
			WgKdf.Kdf1(ck, X25519.ScalarMult(priv, theirEph), tmp); ck = tmp;
			byte[] t2 = new byte[32], key = new byte[32], nck = new byte[32];
			WgKdf.Kdf3(ck, psk, nck, t2, key); ck = nck;
			hash = WgKdf.HashCat(hash, t2);
			byte[] empty = ChaChaPoly.Open(key, 0, encEmpty, hash);
			if (empty == null) return;
			hsHash = WgKdf.HashCat(hash, encEmpty);
			byte[] t1 = new byte[32]; WgKdf.Kdf2(ck, new byte[0], t1, tmp);
			bool firstUp;
			lock (gate) {
				firstUp = !up;
				sendKey = t1; recvKey = tmp; localIndex = hsLocalIndex; remoteIndex = theirIdx;
				sendCtr = 0; recvCtr = 0; up = true;
				lastData = DateTime.UtcNow; lastRecv = DateTime.UtcNow; lastHsOk = DateTime.UtcNow;
			}
			Status = "up " + LocalAddress + " via " + endpoint; LastError = "";
			try { Session.RebindListen(); } catch { }
			WgSend(new byte[0]);
			if (firstUp || string.IsNullOrEmpty(ProvenIp)) BeginProbe();
		}

		static void HandleData(byte[] pkt) {
			if (!up || pkt.Length < 32 || recvKey == null) return;
			uint recvIdx = BitConverter.ToUInt32(pkt, 4);
			if (recvIdx != localIndex) return;
			ulong ctr = BitConverter.ToUInt64(pkt, 8);
			byte[] body = new byte[pkt.Length - 16]; Buffer.BlockCopy(pkt, 16, body, 0, body.Length);
			byte[] inner = ChaChaPoly.Open(recvKey, ctr, body, null);
			if (inner == null) return;
			if (ctr + 1 > recvCtr) recvCtr = ctr + 1;
			OnInnerIp(inner);
		}

		internal static void OnInnerIp(byte[] inner) {
			lastData = DateTime.UtcNow; lastRecv = DateTime.UtcNow;
			if (inner == null || inner.Length < 20) return;
			if ((inner[0] >> 4) != 4) return;
			int ihl = (inner[0] & 0xF) * 4;
			if (ihl < 20 || inner.Length < ihl) return;
			int proto = inner[9];
			uint src = ((uint)inner[12] << 24) | ((uint)inner[13] << 16) | ((uint)inner[14] << 8) | inner[15];
			int tot = (inner[2] << 8) | inner[3]; if (tot > inner.Length) tot = inner.Length;
			if (proto == 17 && tot >= ihl + 8) {
				int sp = (inner[ihl] << 8) | inner[ihl + 1];
				int dp = (inner[ihl + 2] << 8) | inner[ihl + 3];
				int ul = (inner[ihl + 4] << 8) | inner[ihl + 5];
				int pay = ul - 8; if (pay < 0) return;
				if (ihl + 8 + pay > tot) pay = tot - ihl - 8;
				if (pay < 0) return;
				byte[] data = new byte[pay]; Buffer.BlockCopy(inner, ihl + 8, data, 0, pay);
				VpnUdpSock s; lock (gate) { udps.TryGetValue(dp, out s); }
				if (s != null) {
					lock (s.gate) { s.rx.Enqueue(data); s.from.Enqueue(new IPEndPoint(UToIp(src), sp)); }
					s.ev.Set();
				}
			} else if (proto == 6 && tot >= ihl + 20) OnTcp(inner, ihl, tot, src);
		}

		static void OnTcp(byte[] ip, int ihl, int tot, uint src) {
			int sp = (ip[ihl] << 8) | ip[ihl + 1];
			int dp = (ip[ihl + 2] << 8) | ip[ihl + 3];
			uint seq = ((uint)ip[ihl + 4] << 24) | ((uint)ip[ihl + 5] << 16) | ((uint)ip[ihl + 6] << 8) | ip[ihl + 7];
			uint ack = ((uint)ip[ihl + 8] << 24) | ((uint)ip[ihl + 9] << 16) | ((uint)ip[ihl + 10] << 8) | ip[ihl + 11];
			int doff = ((ip[ihl + 12] >> 4) & 0xF) * 4;
			int flags = ip[ihl + 13];
			int payOff = ihl + doff; int payLen = tot - payOff; if (payLen < 0) payLen = 0;
			string k = Key(src, (ushort)sp, (ushort)dp);
			VpnTcp t; lock (gate) { tcps.TryGetValue(k, out t); }
			if (t == null) {
				if ((flags & 2) != 0 && dp == listenPort && listenPort > 0) {
					t = new VpnTcp(); t.locIp = localIp; t.remIp = src; t.locPort = (ushort)dp; t.remPort = (ushort)sp;
					t.rcvNxt = seq + 1; t.iss = (uint)new Random().Next(); t.sndNxt = t.iss + 1; t.sndUna = t.iss + 1; t.state = 2;
					t.sndWScale = ParseWScale(ip, ihl, doff);
					int rw = (ip[ihl + 14] << 8) | ip[ihl + 15]; t.peerWnd = (uint)rw;
					lock (gate) tcps[k] = t;
					TcpSend(t, 0x12, null, t.iss);
				}
				return;
			}
			bool sendSynAckAck = false;
			bool pump = false;
			VpnSeg fastRt = null;
			lock (t.gate) {
				if ((flags & 4) != 0) { t.rst = true; t.state = 0; t.ev.Set(); return; }
				int rawW = (ip[ihl + 14] << 8) | ip[ihl + 15];
				if ((flags & 2) != 0) {
					t.sndWScale = ParseWScale(ip, ihl, doff);
					t.peerWnd = (uint)rawW;
				} else if (t.sndWScale > 0) t.peerWnd = ((uint)rawW) << t.sndWScale;
				else t.peerWnd = (uint)rawW;
				if (t.state == 1 && (flags & 18) == 18) {
					t.rcvNxt = seq + 1; t.state = 3; t.sndUna = t.iss + 1; sendSynAckAck = true;
				}
				if ((flags & 16) != 0) {
					bool progressed = false;
					int before = t.flight.Count;
					while (t.flight.Count > 0) {
						VpnSeg sg = t.flight[0];
						uint end = sg.seq + (uint)sg.data.Length;
						if (ack >= end) { t.flight.RemoveAt(0); t.sndUna = end; progressed = true; }
						else break;
					}
					if (progressed) { t.dupAcks = 0; t.ev.Set(); pump = true; }
					else if (before > 0 && t.flight.Count > 0) {
						t.dupAcks++;
						if (t.dupAcks >= 3) { t.dupAcks = 0; t.flight[0].sent = DateTime.UtcNow; fastRt = t.flight[0]; }
					}
					if (t.state == 2 && (flags & 2) == 0) {
						t.state = 3; lock (gate) accepts.Enqueue(t); acceptEv.Set();
					}
				}
				if (payLen > 0 && t.state == 3) {
					uint pend = seq + (uint)payLen;
					if (seq <= t.rcvNxt && pend > t.rcvNxt) {
						int skip = (int)(t.rcvNxt - seq);
						int keep = payLen - skip;
						byte[] chunk = new byte[keep];
						Buffer.BlockCopy(ip, payOff + skip, chunk, 0, keep);
						t.rxq.Enqueue(chunk); t.rxAvail += keep;
						t.rcvNxt += (uint)keep;
						byte[] more;
						while (t.ooo.TryGetValue(t.rcvNxt, out more)) {
							t.ooo.Remove(t.rcvNxt);
							t.rxq.Enqueue(more); t.rxAvail += more.Length;
							t.rcvNxt += (uint)more.Length;
						}
						t.ev.Set();
						TcpSend(t, 0x10, null, t.sndNxt);
					} else if ((int)(seq - t.rcvNxt) > 0 && (seq - t.rcvNxt) < 2097152u && t.ooo.Count < 96) {
						if (!t.ooo.ContainsKey(seq)) {
							byte[] chunk = new byte[payLen];
							Buffer.BlockCopy(ip, payOff, chunk, 0, payLen);
							t.ooo[seq] = chunk;
						}
						TcpSend(t, 0x10, null, t.sndNxt);
					} else if ((int)(seq - t.rcvNxt) <= 0) {
						TcpSend(t, 0x10, null, t.sndNxt);
					}
				}
				if ((flags & 1) != 0 && t.state == 3) {
					uint fseq = seq + (uint)payLen;
					if (fseq == t.rcvNxt) {
						t.rcvNxt++; TcpSend(t, 0x10, null, t.sndNxt); t.state = 4; t.ev.Set();
					} else if (fseq > t.rcvNxt) { t.finSeen = true; t.finSeq = fseq; }
				}
				if (t.finSeen && t.state == 3 && t.rcvNxt == t.finSeq) {
					t.rcvNxt++; TcpSend(t, 0x10, null, t.sndNxt); t.state = 4; t.ev.Set();
				}
			}
			if (sendSynAckAck) { TcpSend(t, 0x10, null, t.sndNxt); t.ev.Set(); }
			if (fastRt != null) TcpSend(t, 0x18, fastRt.data, fastRt.seq);
			if (pump) TcpPump(t);
		}

		static void TickTcp() {
			List<VpnTcp> list; lock (gate) list = new List<VpnTcp>(tcps.Values);
			DateTime now = DateTime.UtcNow;
			for (int i = 0; i < list.Count; i++) {
				VpnTcp t = list[i];
				VpnSeg oldest = null;
				lock (t.gate) {
					if (t.flight.Count > 0 && (now - t.flight[0].sent).TotalMilliseconds > 400) {
						t.flight[0].sent = now; oldest = t.flight[0];
					}
				}
				if (oldest != null) TcpSend(t, 0x18, oldest.data, oldest.seq);
				TcpPump(t);
			}
		}

		internal static void UdpSendRaw(byte[] msg) {
			UdpClient u = udp;
			IPEndPoint ep = endpoint;
			if (u == null || ep == null) return;
			lock (udpGate) {
				try { u.Send(msg, msg.Length, ep); } catch { }
			}
		}

		static void SendInner(byte[] inner) {
			if (vpnKind == 2) {
				OvpnSess o = ovpn;
				if (o != null) o.SendInner(inner);
				lastData = DateTime.UtcNow;
				return;
			}
			WgSend(inner);
		}

		static void WgSend(byte[] inner) {
			if (sendKey == null || udp == null) return;
			int pad = (16 - (inner.Length % 16)) % 16;
			byte[] plain = new byte[inner.Length + pad];
			Buffer.BlockCopy(inner, 0, plain, 0, inner.Length);
			ulong ctr; uint ridx;
			lock (gate) { ctr = sendCtr++; ridx = remoteIndex; }
			byte[] enc = ChaChaPoly.Seal(sendKey, ctr, plain, null);
			byte[] msg = new byte[16 + enc.Length];
			BitConverter.GetBytes((uint)4).CopyTo(msg, 0);
			BitConverter.GetBytes(ridx).CopyTo(msg, 4);
			BitConverter.GetBytes(ctr).CopyTo(msg, 8);
			Buffer.BlockCopy(enc, 0, msg, 16, enc.Length);
			UdpSendRaw(msg);
			lastData = DateTime.UtcNow;
		}

		static byte[] BuildUdp(uint sip, ushort sp, uint dip, ushort dp, byte[] data) {
			int ul = 8 + data.Length;
			byte[] p = new byte[20 + ul];
			p[0] = 0x45; p[2] = (byte)(p.Length >> 8); p[3] = (byte)p.Length;
			uint id = ++ipId; p[4] = (byte)(id >> 8); p[5] = (byte)id;
			p[8] = 64; p[9] = 17;
			PutIp(p, 12, sip); PutIp(p, 16, dip);
			PutCsum(p, 0, 20, 10);
			p[20] = (byte)(sp >> 8); p[21] = (byte)sp; p[22] = (byte)(dp >> 8); p[23] = (byte)dp;
			p[24] = (byte)(ul >> 8); p[25] = (byte)ul;
			Buffer.BlockCopy(data, 0, p, 28, data.Length);
			PutUdpCsum(p, sip, dip, ul);
			return p;
		}
		static int ParseWScale(byte[] ip, int ihl, int doff) {
			int o = ihl + 20, end = ihl + doff;
			while (o < end) {
				int k = ip[o];
				if (k == 0) break;
				if (k == 1) { o++; continue; }
				if (o + 1 >= end) break;
				int l = ip[o + 1]; if (l < 2 || o + l > end) break;
				if (k == 3 && l == 3) return ip[o + 2];
				o += l;
			}
			return 0;
		}
		static byte[] BuildTcp(uint sip, ushort sp, uint dip, ushort dp, uint seq, uint ack, int flags, byte[] payload) {
			bool syn = (flags & 2) != 0;
			int hl = syn ? 28 : 20;
			int tot = 20 + hl + payload.Length;
			byte[] p = new byte[tot];
			p[0] = 0x45; p[2] = (byte)(tot >> 8); p[3] = (byte)tot;
			uint id = ++ipId; p[4] = (byte)(id >> 8); p[5] = (byte)id;
			p[8] = 64; p[9] = 6;
			PutIp(p, 12, sip); PutIp(p, 16, dip);
			PutCsum(p, 0, 20, 10);
			int o = 20;
			p[o] = (byte)(sp >> 8); p[o + 1] = (byte)sp; p[o + 2] = (byte)(dp >> 8); p[o + 3] = (byte)dp;
			p[o + 4] = (byte)(seq >> 24); p[o + 5] = (byte)(seq >> 16); p[o + 6] = (byte)(seq >> 8); p[o + 7] = (byte)seq;
			p[o + 8] = (byte)(ack >> 24); p[o + 9] = (byte)(ack >> 16); p[o + 10] = (byte)(ack >> 8); p[o + 11] = (byte)ack;
			p[o + 12] = (byte)((hl / 4) << 4); p[o + 13] = (byte)flags;
			p[o + 14] = 0xFF; p[o + 15] = 0xFF;
			if (syn) {
				int mss = VpnTcp.Mss;
				p[o + 20] = 2; p[o + 21] = 4; p[o + 22] = (byte)(mss >> 8); p[o + 23] = (byte)mss;
				p[o + 24] = 1; p[o + 25] = 3; p[o + 26] = 3; p[o + 27] = (byte)VpnTcp.WScale;
			}
			if (payload.Length > 0) Buffer.BlockCopy(payload, 0, p, 20 + hl, payload.Length);
			PutTcpCsum(p, sip, dip, hl + payload.Length);
			return p;
		}
		static void PutIp(byte[] p, int o, uint ip) { p[o] = (byte)(ip >> 24); p[o + 1] = (byte)(ip >> 16); p[o + 2] = (byte)(ip >> 8); p[o + 3] = (byte)ip; }
		static void PutCsum(byte[] p, int o, int n, int csumOff) {
			p[csumOff] = 0; p[csumOff + 1] = 0;
			ushort s = Csum(p, o, n); p[csumOff] = (byte)(s >> 8); p[csumOff + 1] = (byte)s;
		}
		static void PutUdpCsum(byte[] p, uint sip, uint dip, int ul) {
			byte[] ph = new byte[12 + ul];
			PutIp(ph, 0, sip); PutIp(ph, 4, dip); ph[9] = 17; ph[10] = (byte)(ul >> 8); ph[11] = (byte)ul;
			Buffer.BlockCopy(p, 20, ph, 12, ul);
			ushort s = Csum(ph, 0, ph.Length);
			if (s == 0) s = 0xFFFF;
			p[26] = (byte)(s >> 8); p[27] = (byte)s;
		}
		static void PutTcpCsum(byte[] p, uint sip, uint dip, int tl) {
			p[36] = 0; p[37] = 0;
			byte[] ph = new byte[12 + tl];
			PutIp(ph, 0, sip); PutIp(ph, 4, dip); ph[9] = 6; ph[10] = (byte)(tl >> 8); ph[11] = (byte)tl;
			Buffer.BlockCopy(p, 20, ph, 12, tl);
			ushort s = Csum(ph, 0, ph.Length); p[36] = (byte)(s >> 8); p[37] = (byte)s;
		}
		static ushort Csum(byte[] d, int o, int n) {
			uint s = 0; int i = 0;
			while (i + 1 < n) { s += (uint)((d[o + i] << 8) | d[o + i + 1]); i += 2; }
			if (i < n) s += (uint)(d[o + i] << 8);
			while ((s >> 16) != 0) s = (s & 0xffff) + (s >> 16);
			return (ushort)(~s);
		}
		static byte[] Tai() {
			byte[] t = new byte[12];
			DateTime n = DateTime.UtcNow;
			ulong sec = (ulong)((n - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds) + 0x400000000000000aUL;
			uint nano = (uint)n.Millisecond * 1000000U;
			for (int i = 0; i < 8; i++) t[i] = (byte)(sec >> (56 - 8 * i));
			t[8] = (byte)(nano >> 24); t[9] = (byte)(nano >> 16); t[10] = (byte)(nano >> 8); t[11] = (byte)nano;
			return t;
		}
		static byte[] Cat(byte[] a, byte[] b) {
			byte[] c = new byte[a.Length + b.Length]; Buffer.BlockCopy(a, 0, c, 0, a.Length); Buffer.BlockCopy(b, 0, c, a.Length, b.Length); return c;
		}
	}

	public static class Session {
		public const int MaxTorrents = 100;
		public const int GlobalMaxPeers = 500;
		static readonly object gate = new object();
		static readonly List<Engine> engines = new List<Engine>();
		static TcpListener listener;
		static Thread acceptThread;
		static UtpHub utpHub;
		static volatile bool listenRun;
		static bool vpnBound;
		static int boundPort;
		static int peerThreads;
		static readonly Semaphore hashSem = new Semaphore(2, 2);
		static readonly Semaphore announceSem = new Semaphore(16, 16);

		static Session() {
			try {
				int w, io;
				ThreadPool.GetMinThreads(out w, out io);
				if (w < 32) ThreadPool.SetMinThreads(32, Math.Max(io, 16));
			} catch { }
		}

		public static int TorrentCount { get { lock (gate) return engines.Count; } }
		public static int BoundPort { get { lock (gate) return boundPort; } }
		internal static UtpHub Utp { get { return utpHub; } }

		public static bool Register(Engine e) {
			if (e == null) return false;
			lock (gate) {
				if (engines.Count >= MaxTorrents) return false;
				byte[] h = e.InfoHashBytes;
				if (h != null && h.Length == 20) {
					for (int i = 0; i < engines.Count; i++) {
						byte[] oh = engines[i].InfoHashBytes;
						if (oh == null || oh.Length != 20) continue;
						int k = 0;
						for (; k < 20; k++) if (oh[k] != h[k]) break;
						if (k == 20) return false;
					}
				}
				engines.Add(e);
				return true;
			}
		}

		public static void Unregister(Engine e) {
			lock (gate) {
				engines.Remove(e);
				if (engines.Count == 0) StopListen_NoLock();
			}
		}

		public static Engine FindByHash(byte[] hash) {
			if (hash == null || hash.Length != 20) return null;
			lock (gate) {
				for (int i = 0; i < engines.Count; i++) {
					byte[] h = engines[i].InfoHashBytes;
					if (h == null || h.Length != 20) continue;
					int k = 0;
					for (; k < 20; k++) if (h[k] != hash[k]) break;
					if (k == 20) return engines[i];
				}
			}
			return null;
		}

		public static byte[][] AllInfoHashes() {
			lock (gate) {
				List<byte[]> list = new List<byte[]>(engines.Count);
				for (int i = 0; i < engines.Count; i++) {
					byte[] h = engines[i].InfoHashBytes;
					if (h != null && h.Length == 20) list.Add(h);
				}
				return list.ToArray();
			}
		}

		public static bool AnyEncrypt() {
			lock (gate) {
				for (int i = 0; i < engines.Count; i++)
					if (engines[i].Settings != null && engines[i].Settings.EnableEncrypt) return true;
			}
			return false;
		}

		public static int IndexOf(Engine e) {
			lock (gate) return engines.IndexOf(e);
		}

		public static int PeerLimit(Engine e, int want) {
			if (want <= 0) want = 80;
			int n;
			lock (gate) n = engines.Count;
			if (n < 1) n = 1;
			int share = Math.Max(6, GlobalMaxPeers / n);
			return Math.Min(want, share);
		}

		public static bool TryBeginPeer() {
			lock (gate) {
				if (peerThreads >= GlobalMaxPeers) return false;
				peerThreads++;
				return true;
			}
		}

		public static void EndPeer() {
			lock (gate) {
				if (peerThreads > 0) peerThreads--;
			}
		}

		public static bool AcquireHash(Engine e) {
			while (e != null && e.KeepGoing) {
				if (hashSem.WaitOne(200)) return true;
			}
			return false;
		}
		public static void ReleaseHash() {
			try { hashSem.Release(); } catch { }
		}

		public static void AcquireAnnounce() {
			try { announceSem.WaitOne(); } catch { }
		}
		public static void ReleaseAnnounce() {
			try { announceSem.Release(); } catch { }
		}

		public static void RebindListen() {
			int port = 6881;
			bool utp = false;
			lock (gate) {
				if (boundPort > 0) port = boundPort;
				for (int i = 0; i < engines.Count; i++) {
					if (engines[i].Settings == null) continue;
					if (engines[i].Settings.EnableUtp) utp = true;
					if (boundPort <= 0 && engines[i].Settings.ListenPort > 0) port = engines[i].Settings.ListenPort;
				}
				if (engines.Count == 0) { StopListen_NoLock(); return; }
			}
			EnsureListen(port, utp);
		}

		public static int EnsureListen(int port, bool enableUtp) {
			lock (gate) {
				if (VpnHub.HasConfig && !VpnHub.TunnelOn) { StopListen_NoLock(); return 0; }
				if (port <= 0) port = 6881;
				if (VpnHub.HasConfig) {
					if (vpnBound && boundPort > 0) {
						if (enableUtp && utpHub == null) {
							utpHub = new UtpHub();
							if (!utpHub.Start(boundPort)) utpHub = null;
						}
						return boundPort;
					}
					StopListen_NoLock();
					VpnHub.ListenTcp(port);
					vpnBound = true;
					boundPort = port;
					listenRun = true;
					acceptThread = new Thread(AcceptLoopVpn);
					acceptThread.IsBackground = true;
					acceptThread.Name = "pt-accept-wg";
					acceptThread.Start();
					if (enableUtp) {
						utpHub = new UtpHub();
						if (!utpHub.Start(boundPort)) utpHub = null;
					}
					return boundPort;
				}
				if (vpnBound) StopListen_NoLock();
				if (listener != null) {
					if (enableUtp && utpHub == null && boundPort > 0) {
						utpHub = new UtpHub();
						if (!utpHub.Start(boundPort)) utpHub = null;
					}
					return boundPort;
				}
				for (int i = 0; i < 10; i++) {
					try {
						TcpListener l = new TcpListener(IPAddress.Any, port + i);
						l.Start();
						listener = l;
						boundPort = ((IPEndPoint)l.LocalEndpoint).Port;
						listenRun = true;
						acceptThread = new Thread(AcceptLoop);
						acceptThread.IsBackground = true;
						acceptThread.Name = "pt-accept";
						acceptThread.Start();
						if (enableUtp) {
							utpHub = new UtpHub();
							if (!utpHub.Start(boundPort)) utpHub = null;
						}
						return boundPort;
					} catch {
						listener = null;
					}
				}
				boundPort = port;
				return 0;
			}
		}

		static void StopListen_NoLock() {
			listenRun = false;
			try { if (listener != null) listener.Stop(); } catch { }
			listener = null;
			try { VpnHub.ListenTcp(-1); } catch { }
			vpnBound = false;
			try { if (utpHub != null) utpHub.Stop(); } catch { }
			utpHub = null;
			boundPort = 0;
		}

		static void AcceptLoop() {
			while (listenRun && listener != null) {
				try {
					if (!listener.Server.Poll(500000, SelectMode.SelectRead)) continue;
					TcpClient c = listener.AcceptTcpClient();
					if (!TryBeginPeer()) {
						try { c.Close(); } catch { }
						continue;
					}
					Thread t = new Thread(delegate(object state) {
						try { DispatchTcp((TcpClient)state); }
						finally { EndPeer(); }
					});
					t.IsBackground = true;
					t.Name = "pt-in";
					t.Start(c);
				} catch {
					if (!listenRun) break;
				}
			}
		}

		static void AcceptLoopVpn() {
			while (listenRun) {
				try {
					VpnTcp v = VpnHub.AcceptTcp(500);
					if (v == null) continue;
					if (!TryBeginPeer()) {
						try { v.Close(); } catch { }
						continue;
					}
					Thread t = new Thread(delegate(object state) {
						try { DispatchVpnTcp((VpnTcp)state); }
						finally { EndPeer(); }
					});
					t.IsBackground = true;
					t.Name = "pt-in-wg";
					t.Start(v);
				} catch {
					if (!listenRun) break;
				}
			}
		}

		static void DispatchVpnTcp(VpnTcp v) {
			TcpPeerIo io = null;
			try {
				io = new TcpPeerIo(v);
				Engine e;
				if (!io.AcceptRouted(AnyEncrypt(), out e) || e == null) {
					io.Close();
					return;
				}
				if (!e.IsRunning || e.IsPaused) {
					io.Close();
					return;
				}
				int lim = PeerLimit(e, e.Settings.MaxPeers);
				if (e.ActivePeerThreads >= lim) {
					io.Close();
					return;
				}
				e.RunIncoming(io);
			} catch {
				try { if (io != null) io.Close(); else v.Close(); } catch { }
			}
		}

		static void DispatchTcp(TcpClient c) {
			TcpPeerIo io = null;
			try {
				io = new TcpPeerIo(c);
				Engine e;
				if (!io.AcceptRouted(AnyEncrypt(), out e) || e == null) {
					io.Close();
					return;
				}
				if (!e.IsRunning || e.IsPaused) {
					io.Close();
					return;
				}
				int lim = PeerLimit(e, e.Settings.MaxPeers);
				if (e.ActivePeerThreads >= lim) {
					io.Close();
					return;
				}
				e.RunIncoming(io);
			} catch {
				try { if (io != null) io.Close(); else c.Close(); } catch { }
			}
		}

		internal static void DispatchUtp(UtpConn c) {
			if (!TryBeginPeer()) {
				try { c.Close(); } catch { }
				return;
			}
			Thread t = new Thread(delegate() {
				try { DispatchUtpCore(c); }
				finally { EndPeer(); }
			});
			t.IsBackground = true;
			t.Name = "pt-utp-in";
			t.Start();
		}

		static void DispatchUtpCore(UtpConn c) {
			UtpPeerIo io = new UtpPeerIo(c);
			try {
				byte[] hs = new byte[68];
				if (!io.ReadExact(hs, 0, 68, 15000) || hs[0] != 19) {
					io.Close();
					return;
				}
				byte[] ih = new byte[20];
				Buffer.BlockCopy(hs, 28, ih, 0, 20);
				Engine e = FindByHash(ih);
				if (e == null || !e.IsRunning || e.IsPaused) {
					io.Close();
					return;
				}
				if (e.ActivePeerThreads >= PeerLimit(e, e.Settings.MaxPeers)) {
					io.Close();
					return;
				}
				io.Unread(hs, 0, 68);
				e.RunIncoming(io);
			} catch {
				try { io.Close(); } catch { }
			}
		}
	}

	public sealed class Engine {
		EngineSettings settings;
		EngineStatus status = new EngineStatus();
		Meta meta;
		PieceMgr pieces;
		byte[] infoHash;
		byte[] peerId;
		volatile bool running;
		volatile bool paused;
		object peerLock = new object();
		List<PeerWorker> peers = new List<PeerWorker>();
		object poolLock = new object();
		Queue<string> pool = new Queue<string>();
		HashSet<string> seen = new HashSet<string>();
		object logLock = new object();
		List<string> logs = new List<string>();
		int logLevel;
		int boundPort;
		long sessionDown;
		long sessionUp;
		double downBps;
		double upBps;
		long lastDl;
		long lastUl;
		DateTime lastSp = DateTime.UtcNow;
		DateTime lastRecycle = DateTime.MinValue;
		int activePeerThreads;
		Thread coordThread;
		Thread dhtThread;
		bool sessionReg;
		int announceInterval = 1800;
		bool startedAnnounced;
		int trackerSeeds;
		object statusLock = new object();
		byte[] rawInfo;
		byte[] fetchedInfo;
		volatile bool infoReady;
		object metaLock = new object();
		int mdSize = -1;
		byte[][] mdPieces;
		bool[] mdHave;
		int mdGot;
		List<string> magnetTrackers = new List<string>();
		List<string> magnetWebseeds = new List<string>();
		byte[] v2Hash;
		bool v2Only;

		sealed class FileEnt {
			public string Path;
			public string RelPath;
			public long Length;
			public long Offset;
			public int Index;
			public byte[] PiecesRoot;
			public byte[] LayerHashes;
		}

		sealed class Meta {
			public string Name;
			public string Comment;
			public string CreatedBy;
			public byte[] InfoHash;
			public string InfoHashHex;
			public int PieceLength;
			public int PieceCount;
			public long TotalSize;
			public byte[] PieceHashes;
			public List<string> Trackers = new List<string>();
			public List<string> Webseeds = new List<string>();
			public List<FileEnt> Files = new List<FileEnt>();
			public bool IsMulti;
			public byte[] RawInfo;
			public bool V2;
			public byte[] V2Hash;
			public Dictionary<string, byte[]> PieceLayers = new Dictionary<string, byte[]>();

			public static Meta Stub(string name, byte[] hash, List<string> trackers, List<string> webseeds) {
				Meta m = new Meta();
				m.InfoHash = hash;
				m.InfoHashHex = BitConverter.ToString(hash).Replace("-", "").ToLowerInvariant();
				if (string.IsNullOrEmpty(name)) name = "magnet-" + m.InfoHashHex.Substring(0, 12);
				m.Name = Bt.SafeName(name);
				if (trackers != null) {
					HashSet<string> seenT = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
					for (int i = 0; i < trackers.Count; i++) AddTracker(m, seenT, trackers[i]);
				}
				if (webseeds != null) {
					for (int i = 0; i < webseeds.Count; i++) AddWeb(m, webseeds[i]);
				}
				return m;
			}

			public static Meta FromInfoBytes(byte[] rawInfo, string savePath) {
				Be info = Benc.Decode(rawInfo);
				if (info == null || info.Dict == null) throw new Exception("invalid info dict");
				Meta m = new Meta();
				m.RawInfo = rawInfo;
				FillInfo(m, info, savePath);
				if (m.V2 && m.PieceHashes == null) {
					byte[] h256 = Crypto.Sha256All(rawInfo);
					m.V2Hash = h256;
					m.InfoHash = new byte[20];
					Buffer.BlockCopy(h256, 0, m.InfoHash, 0, 20);
				} else {
					using (SHA1CryptoServiceProvider sha = new SHA1CryptoServiceProvider()) {
						m.InfoHash = sha.ComputeHash(rawInfo);
					}
				}
				m.InfoHashHex = BitConverter.ToString(m.InfoHash).Replace("-", "").ToLowerInvariant();
				return m;
			}

			public static Meta Load(byte[] torrentBytes, string savePath) {
				Be root = Benc.Decode(torrentBytes);
				if (root.Dict == null) throw new Exception("torrent is not a dictionary");
				Be info = root.Get("info");
				if (info == null || info.Dict == null) throw new Exception("torrent missing info dict");

				byte[] rawInfo = Benc.SliceDictValue(torrentBytes, "info");
				if (rawInfo == null) rawInfo = Benc.Encode(info);

				Meta m = new Meta();
				m.RawInfo = rawInfo;
				FillInfo(m, info, savePath);
				if (m.V2 && m.PieceHashes == null) {
					byte[] h256 = Crypto.Sha256All(rawInfo);
					m.V2Hash = h256;
					m.InfoHash = new byte[20];
					Buffer.BlockCopy(h256, 0, m.InfoHash, 0, 20);
				} else {
					using (SHA1CryptoServiceProvider sha = new SHA1CryptoServiceProvider()) {
						m.InfoHash = sha.ComputeHash(rawInfo);
					}
					if (m.V2) m.V2Hash = Crypto.Sha256All(rawInfo);
				}
				m.InfoHashHex = BitConverter.ToString(m.InfoHash).Replace("-", "").ToLowerInvariant();
				Be layers = root.Get("piece layers");
				if (layers != null && layers.Pairs != null) {
					for (int i = 0; i < layers.Pairs.Count; i++) {
						byte[] k = layers.Pairs[i].Key;
						Be v = layers.Pairs[i].Value;
						if (k != null && k.Length == 32 && v != null && v.Bytes != null)
							m.PieceLayers[BitConverter.ToString(k).Replace("-", "")] = v.Bytes;
					}
				}
				ApplyLayers(m);
				m.Comment = root.Str("comment") ?? "";
				m.CreatedBy = root.Str("created by") ?? "";

				HashSet<string> seenT = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
				string ann = root.Str("announce");
				AddTracker(m, seenT, ann);
				Be al = root.Get("announce-list");
				if (al != null && al.List != null) {
					for (int t = 0; t < al.List.Count; t++) {
						Be tier = al.List[t];
						if (tier.List != null) {
							for (int u = 0; u < tier.List.Count; u++) {
								if (tier.List[u].Bytes != null)
									AddTracker(m, seenT, Encoding.UTF8.GetString(tier.List[u].Bytes));
							}
						} else if (tier.Bytes != null) {
							AddTracker(m, seenT, Encoding.UTF8.GetString(tier.Bytes));
						}
					}
				}

				Be ul = root.Get("url-list");
				if (ul != null) {
					if (ul.Bytes != null) AddWeb(m, Encoding.UTF8.GetString(ul.Bytes));
					else if (ul.List != null) {
						for (int i = 0; i < ul.List.Count; i++) {
							if (ul.List[i].Bytes != null) AddWeb(m, Encoding.UTF8.GetString(ul.List[i].Bytes));
						}
					}
				}
				return m;
			}

			static void FillInfo(Meta m, Be info, string savePath) {
				m.Name = info.Str("name");
				if (string.IsNullOrEmpty(m.Name)) m.Name = "download";
				m.Name = Bt.SafeName(m.Name);

				long pl = info.GetInt("piece length", 0);
				if (pl < 16 || pl > 32L * 1024 * 1024) throw new Exception("invalid piece length");
				m.PieceLength = (int)pl;

				Be piecesBe = info.Get("pieces");
				bool haveV1 = piecesBe != null && piecesBe.Bytes != null && piecesBe.Bytes.Length % 20 == 0 && piecesBe.Bytes.Length > 0;
				if (haveV1) m.PieceHashes = piecesBe.Bytes;
				if (info.GetInt("meta version", 1) >= 2) m.V2 = true;

				string saveRoot = savePath;
				if (string.IsNullOrEmpty(saveRoot)) saveRoot = Directory.GetCurrentDirectory();

				Be tree = info.Get("file tree");
				if (tree != null && tree.Dict != null) {
					m.V2 = true;
					long[] off = new long[1];
					WalkTree(tree, "", saveRoot, m, off);
					m.TotalSize = off[0];
					m.IsMulti = m.Files.Count > 1;
					if (m.IsMulti) {
						for (int fi = 0; fi < m.Files.Count; fi++) {
							m.Files[fi].RelPath = m.Name + "/" + m.Files[fi].RelPath;
							m.Files[fi].Path = Path.Combine(saveRoot, m.Files[fi].RelPath.Replace('/', Path.DirectorySeparatorChar));
						}
					} else if (m.Files.Count == 1) {
						if (string.IsNullOrEmpty(m.Files[0].RelPath)) m.Files[0].RelPath = m.Name;
						m.Files[0].Path = Path.Combine(saveRoot, m.Files[0].RelPath.Replace('/', Path.DirectorySeparatorChar));
					}
				} else {
				Be filesBe = info.Get("files");
				if (filesBe != null && filesBe.List != null) {
					m.IsMulti = true;
					long off = 0;
					for (int fi = 0; fi < filesBe.List.Count; fi++) {
						Be f = filesBe.List[fi];
						if (f.Dict == null) throw new Exception("invalid file entry");
						long len = f.GetInt("length", -1);
						if (len < 0) throw new Exception("file missing length");
						Be pathBe = f.Get("path");
						if (pathBe == null || pathBe.List == null || pathBe.List.Count == 0)
							throw new Exception("file missing path");
						string rel = m.Name;
						string abs = Path.Combine(saveRoot, m.Name);
						for (int p = 0; p < pathBe.List.Count; p++) {
							if (pathBe.List[p].Bytes == null) throw new Exception("invalid path element");
							string part = Bt.SafeName(Encoding.UTF8.GetString(pathBe.List[p].Bytes));
							rel = rel + "/" + part;
							abs = Path.Combine(abs, part);
						}
						FileEnt e = new FileEnt();
						e.Path = abs;
						e.RelPath = rel;
						e.Length = len;
						e.Offset = off;
						e.Index = fi;
						m.Files.Add(e);
						off += len;
					}
					m.TotalSize = off;
				} else {
					m.IsMulti = false;
					long len = info.GetInt("length", -1);
					if (len < 0) throw new Exception("torrent missing length");
					FileEnt e = new FileEnt();
					e.Path = Path.Combine(saveRoot, m.Name);
					e.RelPath = m.Name;
					e.Length = len;
					e.Offset = 0;
					e.Index = 0;
					m.Files.Add(e);
					m.TotalSize = len;
				}
				}

				if (m.TotalSize == 0) m.PieceCount = 0;
				else m.PieceCount = (int)((m.TotalSize + m.PieceLength - 1) / m.PieceLength);
				if (m.PieceHashes != null && m.PieceHashes.Length != m.PieceCount * 20)
					throw new Exception("pieces length does not match file size");
				if (m.PieceHashes == null && !m.V2)
					throw new Exception("invalid pieces field");
				ApplyLayers(m);
			}

			static void WalkTree(Be node, string relBase, string saveRoot, Meta m, long[] off) {
				if (node == null || node.Dict == null) return;
				Be leaf = node.Get("");
				if (leaf != null && leaf.Dict != null) {
					long len = leaf.GetInt("length", 0);
					Be pr = leaf.Get("pieces root");
					FileEnt e = new FileEnt();
					e.RelPath = relBase.Replace('\\', '/');
					e.Path = Path.Combine(saveRoot, e.RelPath.Replace('/', Path.DirectorySeparatorChar));
					e.Length = len;
					e.Offset = off[0];
					e.Index = m.Files.Count;
					if (pr != null) e.PiecesRoot = pr.Bytes;
					m.Files.Add(e);
					off[0] += len;
					return;
				}
				foreach (KeyValuePair<string, Be> kv in node.Dict) {
					if (kv.Key == "") continue;
					string child = relBase.Length == 0 ? Bt.SafeName(kv.Key) : relBase + "/" + Bt.SafeName(kv.Key);
					WalkTree(kv.Value, child, saveRoot, m, off);
				}
			}

			static void ApplyLayers(Meta m) {
				if (m.PieceLayers == null || m.PieceLayers.Count == 0) return;
				for (int i = 0; i < m.Files.Count; i++) {
					FileEnt f = m.Files[i];
					if (f.PiecesRoot == null || f.PiecesRoot.Length != 32) continue;
					string k = BitConverter.ToString(f.PiecesRoot).Replace("-", "");
					byte[] layers;
					if (m.PieceLayers.TryGetValue(k, out layers)) f.LayerHashes = layers;
				}
			}

			static void AddTracker(Meta m, HashSet<string> seenT, string url) {
				if (string.IsNullOrEmpty(url)) return;
				url = url.Trim();
				if (url.Length == 0) return;
				if (!seenT.Add(url)) return;
				m.Trackers.Add(url);
			}
			static void AddWeb(Meta m, string url) {
				if (string.IsNullOrEmpty(url)) return;
				url = url.Trim();
				if (url.Length == 0) return;
				m.Webseeds.Add(url);
			}
		}

		sealed class PieceMgr {
			Engine eng;
			Meta m;
			FileStream[] streams;
			object gate = new object();
			bool[] done;
			int[] avail;
			byte[][] buf;
			byte[][] st;
			int[][] hits;
			int n;
			int pieceLen;
			long total;
			int doneCount;
			long verified;
			long pending;
			int inFlight;
			int maxInFlight;
			const int BS = 16384;
			List<int> open;
			int[] posInOpen;
			[ThreadStatic] static SHA1CryptoServiceProvider tlsSha1;

			public PieceMgr(Engine eng, Meta m) {
				this.eng = eng;
				this.m = m;
				n = m.PieceCount;
				pieceLen = m.PieceLength;
				total = m.TotalSize;
				done = new bool[Math.Max(n, 0)];
				avail = new int[Math.Max(n, 0)];
				buf = new byte[Math.Max(n, 0)][];
				st = new byte[Math.Max(n, 0)][];
				hits = new int[Math.Max(n, 0)][];
				open = new List<int>(Math.Max(n, 0));
				posInOpen = new int[Math.Max(n, 0)];
				for (int i = 0; i < n; i++) {
					posInOpen[i] = i;
					open.Add(i);
				}
				RefreshBudget();
			}

			public void RefreshBudget() {
				int denom = Math.Max(16384, pieceLen);
				int nT = Math.Max(1, Session.TorrentCount);
				long share = (48L * 1024 * 1024) / nT;
				int byMem = (int)(share / denom);
				int cap = nT > 25 ? 16 : (nT > 10 ? 32 : 96);
				maxInFlight = Math.Max(4, Math.Min(cap, Math.Max(4, byMem)));
			}

			public bool IsComplete { get { return n == 0 || doneCount >= n; } }
			public int DoneCount { get { return doneCount; } }
			public bool IsEndgame() {
				int left = n - doneCount;
				if (left <= 0) return false;
				if (left <= 4) return true;
				return RemainingBlocks() <= 96;
			}

			public void Open() {
				streams = new FileStream[m.Files.Count];
				for (int i = 0; i < m.Files.Count; i++) {
					FileEnt f = m.Files[i];
					string dir = Path.GetDirectoryName(f.Path);
					if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir)) Directory.CreateDirectory(dir);
					streams[i] = new FileStream(f.Path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.ReadWrite, 1024 * 1024, FileOptions.SequentialScan);
					if (streams[i].Length != f.Length) streams[i].SetLength(f.Length);
				}
			}

			public void Close() {
				if (streams == null) return;
				for (int i = 0; i < streams.Length; i++) {
					if (streams[i] != null) {
						try { streams[i].Flush(); streams[i].Close(); } catch { }
						streams[i] = null;
					}
				}
			}

			public int PieceSize(int idx) {
				if (idx < 0 || idx >= n) return 0;
				if (idx < n - 1) return pieceLen;
				long rem = total - (long)idx * (long)pieceLen;
				return (int)rem;
			}

			int BlockCount(int idx) {
				int sz = PieceSize(idx);
				if (sz <= 0) return 0;
				return (sz + BS - 1) / BS;
			}

			int BlockLen(int idx, int b) {
				int sz = PieceSize(idx);
				int off = b * BS;
				int left = sz - off;
				if (left <= 0) return 0;
				return left > BS ? BS : left;
			}

			void IO(long offset, byte[] buffer, int bufOff, int len, bool write) {
				int remain = len;
				for (int fi = 0; fi < m.Files.Count && remain > 0; fi++) {
					FileEnt f = m.Files[fi];
					long fe = f.Offset + f.Length;
					if (offset >= fe || offset < f.Offset) continue;
					long local = offset - f.Offset;
					int nbyte = (int)Math.Min((long)remain, f.Length - local);
					FileStream s = streams[f.Index];
					lock (s) {
						s.Seek(local, SeekOrigin.Begin);
						if (write) {
							s.Write(buffer, bufOff, nbyte);
						} else {
							int need = nbyte;
							int o = bufOff;
							while (need > 0) {
								int g = s.Read(buffer, o, need);
								if (g <= 0) throw new IOException("short read");
								need -= g;
								o += g;
							}
						}
					}
					offset += nbyte;
					bufOff += nbyte;
					remain -= nbyte;
				}
				if (remain != 0) throw new IOException("io span");
			}

			public void HashCheck() {
				if (n == 0) return;
				if (!Session.AcquireHash(eng)) return;
				try {
				RefreshBudget();
				int workers = Math.Max(1, Math.Min(Environment.ProcessorCount, 8));
				int nT = Session.TorrentCount;
				if (nT > 8) workers = 1;
				else if (nT > 3) workers = Math.Min(2, workers);
				if (n < 24) workers = 1;
				if (workers == 1) {
					byte[] tmp = new byte[pieceLen];
					for (int i = 0; i < n && eng.running; i++) {
						while (eng.paused && eng.running) Thread.Sleep(100);
						if (!eng.running) return;
						HashOne(i, tmp);
						if ((i & 15) == 0) eng.OnHashProgress(i + 1, n);
					}
				} else {
					int next = 0;
					int hashed = 0;
					object progLock = new object();
					Thread[] th = new Thread[workers];
					for (int w = 0; w < workers; w++) {
						th[w] = new Thread(delegate() {
							byte[] tmp = new byte[pieceLen];
							while (eng.running) {
								int i;
								lock (progLock) {
									if (next >= n) return;
									i = next++;
								}
								while (eng.paused && eng.running) Thread.Sleep(100);
								if (!eng.running) return;
								HashOne(i, tmp);
								int h = Interlocked.Increment(ref hashed);
								if ((h & 15) == 0) eng.OnHashProgress(h, n);
							}
						});
						th[w].IsBackground = true;
						th[w].Name = "pt-hash";
						th[w].Start();
					}
					for (int w = 0; w < workers; w++) {
						try { th[w].Join(); } catch { }
					}
				}
				RebuildOpen();
				eng.OnHashProgress(n, n);
				} finally {
					Session.ReleaseHash();
				}
			}

			void HashOne(int i, byte[] tmp) {
				int sz = PieceSize(i);
				bool readOk = true;
				try { IO((long)i * (long)pieceLen, tmp, 0, sz, false); }
				catch { readOk = false; }
				if (readOk && VerifyPieceData(i, tmp, sz)) {
					done[i] = true;
					Interlocked.Increment(ref doneCount);
					Interlocked.Add(ref verified, sz);
				}
			}

			void RebuildOpen() {
				open.Clear();
				for (int i = 0; i < n; i++) {
					if (!done[i]) {
						posInOpen[i] = open.Count;
						open.Add(i);
					} else posInOpen[i] = -1;
				}
			}

			void RemoveOpen(int piece) {
				if (piece < 0 || piece >= n) return;
				int at = posInOpen[piece];
				if (at < 0) return;
				int lastIdx = open.Count - 1;
				int last = open[lastIdx];
				open[at] = last;
				posInOpen[last] = at;
				open.RemoveAt(lastIdx);
				posInOpen[piece] = -1;
			}

			bool VerifyPieceData(int piece, byte[] data, int sz) {
				if (m.PieceHashes != null && m.PieceHashes.Length >= (piece + 1) * 20) {
					byte[] h;
					SHA1CryptoServiceProvider sha = tlsSha1;
					if (sha == null) {
						sha = new SHA1CryptoServiceProvider();
						tlsSha1 = sha;
					}
					h = sha.ComputeHash(data, 0, sz);
					int ho = piece * 20;
					for (int k = 0; k < 20; k++) if (h[k] != m.PieceHashes[ho + k]) return false;
					return true;
				}
				if (m.V2) {
					byte[] layer = Crypto.MerklePiece(data, sz);
					long off = (long)piece * (long)pieceLen;
					for (int fi = 0; fi < m.Files.Count; fi++) {
						FileEnt f = m.Files[fi];
						if (off < f.Offset || off >= f.Offset + f.Length) continue;
						if (f.LayerHashes != null && f.LayerHashes.Length >= 32) {
							int local = (int)((off - f.Offset) / pieceLen);
							int lo = local * 32;
							if (lo + 32 > f.LayerHashes.Length) return false;
							for (int k = 0; k < 32; k++) if (layer[k] != f.LayerHashes[lo + k]) return false;
							return true;
						}
						if (f.PiecesRoot != null && f.Length <= pieceLen) {
							for (int k = 0; k < 32; k++) if (layer[k] != f.PiecesRoot[k]) return false;
							return true;
						}
						return true;
					}
					return true;
				}
				return false;
			}

			bool HasFreeBlock(int idx, bool endgame) {
				int bc = BlockCount(idx);
				if (st[idx] == null) return true;
				for (int b = 0; b < bc; b++) {
					if (st[idx][b] == 0) return true;
					if (endgame && st[idx][b] == 1) return true;
				}
				return false;
			}

			int Pick(BitArray has, bool sequential, bool endgame) {
				int best = -1;
				int bestScore = int.MaxValue;
				int cnt = open.Count;
				for (int k = 0; k < cnt; k++) {
					int i = open[k];
					if (has != null && (i >= has.Length || !has[i])) continue;
					if (!HasFreeBlock(i, endgame)) continue;
					if (st[i] == null && !endgame && inFlight >= maxInFlight && (n - doneCount) > maxInFlight) continue;
					if (sequential) return i;
					int score = (st[i] != null) ? avail[i] - 100000 : avail[i];
					if (score < bestScore) { bestScore = score; best = i; }
				}
				return best;
			}

			public bool TryClaim(BitArray has, bool sequential, bool endgame, out int piece, out int begin, out int length) {
				piece = -1;
				begin = 0;
				length = 0;
				lock (gate) {
					int pick = Pick(has, sequential, endgame);
					if (pick < 0) return false;
					int bc = BlockCount(pick);
					if (st[pick] == null) {
						st[pick] = new byte[bc];
						hits[pick] = new int[bc];
						buf[pick] = new byte[PieceSize(pick)];
						inFlight++;
					}
					for (int b = 0; b < bc; b++) {
						if (st[pick][b] == 0) {
							st[pick][b] = 1;
							hits[pick][b]++;
							piece = pick;
							begin = b * BS;
							length = BlockLen(pick, b);
							return true;
						}
					}
					if (endgame) {
						int best = -1, bestH = int.MaxValue;
						for (int b = 0; b < bc; b++) {
							if (st[pick][b] == 1 && hits[pick][b] < bestH) { bestH = hits[pick][b]; best = b; }
						}
						if (best >= 0 && bestH < 12) {
							hits[pick][best]++;
							piece = pick;
							begin = best * BS;
							length = BlockLen(pick, best);
							return true;
						}
					}
					return false;
				}
			}

			public void Unclaim(int piece, int begin) {
				lock (gate) {
					if (piece < 0 || piece >= n || st[piece] == null) return;
					int b = begin / BS;
					if (b >= 0 && b < st[piece].Length && st[piece][b] == 1) st[piece][b] = 0;
				}
			}

			void AbortPiece(int piece, int sz) {
				pending -= sz;
				if (pending < 0) pending = 0;
				st[piece] = null;
				hits[piece] = null;
				buf[piece] = null;
				inFlight--;
			}

			// 0 = rejected, 1 = block stored, 2 = piece verified and written
			public int Submit(int piece, int begin, byte[] data, int off, int len) {
				byte[] pieceData = null;
				int sz = 0;
				lock (gate) {
					if (piece < 0 || piece >= n || done[piece]) return 0;
					if (st[piece] == null || buf[piece] == null) return 0;
					int b = begin / BS;
					if (b < 0 || b >= st[piece].Length) return 0;
					int expect = BlockLen(piece, b);
					if (len != expect) return 0;
					if (st[piece][b] == 2) return 0;
					Buffer.BlockCopy(data, off, buf[piece], begin, len);
					st[piece][b] = 2;
					pending += len;
					eng.AddSessionDown(len);
					int bc = st[piece].Length;
					for (int k = 0; k < bc; k++) if (st[piece][k] != 2) return 1;
					sz = PieceSize(piece);
					pieceData = buf[piece];
					buf[piece] = null;
				}
				bool ok = VerifyPieceData(piece, pieceData, sz);
				if (!ok) {
					eng.Log(1, "piece " + piece.ToString(CultureInfo.InvariantCulture) + " hash mismatch, retrying");
					lock (gate) AbortPiece(piece, sz);
					return 0;
				}
				try {
					IO((long)piece * (long)pieceLen, pieceData, 0, sz, true);
				} catch (Exception ex) {
					eng.Log(0, "write failed: " + ex.Message);
					lock (gate) AbortPiece(piece, sz);
					return 0;
				}
				lock (gate) {
					if (done[piece]) return 2;
					done[piece] = true;
					doneCount++;
					verified += sz;
					pending -= sz;
					if (pending < 0) pending = 0;
					st[piece] = null;
					hits[piece] = null;
					inFlight--;
					RemoveOpen(piece);
				}
				return 2;
			}

			public bool Has(int piece) {
				if (piece < 0 || piece >= n) return false;
				return done[piece];
			}

			public byte[] ReadBlock(int piece, int begin, int length) {
				lock (gate) {
					if (!Has(piece)) return null;
					int sz = PieceSize(piece);
					if (begin < 0 || length <= 0 || begin + (long)length > sz) return null;
				}
				byte[] data = new byte[length];
				try { IO((long)piece * (long)pieceLen + begin, data, 0, length, false); }
				catch { return null; }
				return data;
			}

			public double Availability() {
				lock (gate) {
					int cnt = open.Count;
					if (cnt == 0) return 0;
					int min = int.MaxValue;
					int atMin = 0;
					for (int k = 0; k < cnt; k++) {
						int a = avail[open[k]];
						if (a < min) { min = a; atMin = 1; }
						else if (a == min) atMin++;
					}
					if (min == int.MaxValue) return 0;
					return min + (double)(cnt - atMin) / (double)cnt;
				}
			}

			public void AddAvail(BitArray has) {
				lock (gate) {
					if (has == null) return;
					int lim = Math.Min(n, has.Length);
					for (int i = 0; i < lim; i++) if (has[i]) avail[i]++;
				}
			}
			public void SubAvail(BitArray has) {
				lock (gate) {
					if (has == null) return;
					int lim = Math.Min(n, has.Length);
					for (int i = 0; i < lim; i++) if (has[i] && avail[i] > 0) avail[i]--;
				}
			}
			public void AddAvailOne(int idx) {
				lock (gate) {
					if (idx >= 0 && idx < n) avail[idx]++;
				}
			}

			public bool PeerHasSomethingWeNeed(BitArray has) {
				if (has == null) return false;
				int lim = Math.Min(n, has.Length);
				for (int i = 0; i < lim; i++) if (!done[i] && has[i]) return true;
				return false;
			}

			public int RemainingBlocks() {
				lock (gate) {
					int c = 0;
					int cnt = open.Count;
					for (int k = 0; k < cnt; k++) {
						int i = open[k];
						int bc = BlockCount(i);
						if (st[i] == null) { c += bc; continue; }
						for (int b = 0; b < bc; b++) if (st[i][b] != 2) c++;
					}
					return c;
				}
			}

			public byte[] MakeBitfield() {
				int blen = (n + 7) / 8;
				byte[] bf = new byte[blen];
				for (int i = 0; i < n; i++) {
					if (done[i]) bf[i / 8] |= (byte)(1 << (7 - (i % 8)));
				}
				return bf;
			}

			public void Snapshot(out int dc, out int tot, out long ver, out long totb) {
				dc = doneCount;
				tot = n;
				ver = verified + pending;
				totb = total;
			}

			public void FillFileProgress(FileRow[] rows) {
				if (rows == null || m == null || m.Files == null) return;
				int nf = rows.Length;
				if (nf > m.Files.Count) nf = m.Files.Count;
				lock (gate) {
					for (int fi = 0; fi < nf; fi++) {
						FileRow row = rows[fi];
						if (row == null) continue;
						FileEnt f = m.Files[fi];
						long len = f.Length;
						if (len <= 0) {
							row.Progress = 100;
							row.ProgressText = "100.0%";
							continue;
						}
						if (n <= 0) {
							row.Progress = 0;
							row.ProgressText = "0.0%";
							continue;
						}
						long got = 0;
						long start = f.Offset;
						long end = start + len;
						int p0 = (int)(start / pieceLen);
						int p1 = (int)((end - 1) / pieceLen);
						if (p0 < 0) p0 = 0;
						if (p1 >= n) p1 = n - 1;
						for (int p = p0; p <= p1; p++) {
							long ps = (long)p * (long)pieceLen;
							int psz = PieceSize(p);
							long pe = ps + psz;
							if (done[p]) {
								long a = start > ps ? start : ps;
								long b = end < pe ? end : pe;
								if (b > a) got += b - a;
								continue;
							}
							if (st[p] == null) continue;
							int bc = st[p].Length;
							for (int bi = 0; bi < bc; bi++) {
								if (st[p][bi] != 2) continue;
								long bs = ps + (long)bi * BS;
								int bl = BlockLen(p, bi);
								long be = bs + bl;
								long a = start > bs ? start : bs;
								long b = end < be ? end : be;
								if (b > a) got += b - a;
							}
						}
						if (got > len) got = len;
						double pct = 100.0 * got / len;
						row.Progress = pct;
						row.ProgressText = pct.ToString("0.0", CultureInfo.InvariantCulture) + "%";
					}
				}
			}
		}

		sealed class PeerWorker {
			Engine eng;
			string host;
			int port;
			TcpClient tcp;
			PeerIo io;
			object wlock = new object();
			bool incoming;
			bool amChoked = true;
			BitArray their;
			List<int> claimsPiece = new List<int>();
			List<int> claimsBegin = new List<int>();
			List<DateTime> claimAt = new List<DateTime>();
			DateTime lastRecv;
			DateTime lastSend;
			bool addedAvail;
			bool theyExt;
			int theirUtMeta;
			int theirUtPex;
			byte[] pendingBitfield;
			List<int> pendingHaves = new List<int>();
			int lastMetaIdx = -1;
			DateTime lastMetaAt = DateTime.MinValue;
			int theyHave;
			bool theySeed;
			public bool IsSeed { get { return theySeed; } }

			public PeerWorker(Engine eng, PeerIo ready) {
				this.eng = eng;
				this.io = ready;
				incoming = true;
				host = "incoming";
				port = 0;
			}
			public PeerWorker(Engine eng, string host, int port) {
				this.eng = eng;
				this.host = host;
				this.port = port;
				incoming = false;
			}
			public PeerWorker(Engine eng, TcpClient c) {
				this.eng = eng;
				this.tcp = c;
				incoming = true;
				try {
					IPEndPoint ep = (IPEndPoint)c.Client.RemoteEndPoint;
					host = ep.Address.ToString();
					port = ep.Port;
				} catch {
					host = "incoming";
					port = 0;
				}
			}
			public PeerWorker(Engine eng, UtpConn uc) {
				this.eng = eng;
				this.io = new UtpPeerIo(uc);
				incoming = true;
				host = uc.Remote.Address.ToString();
				port = uc.Remote.Port;
			}

			public void Run() {
				try {
					if (!Connect()) {
						eng.Log(2, "connect failed " + host + ":" + port.ToString(CultureInfo.InvariantCulture));
						return;
					}
					string via = (io != null) ? io.Transport : "TCP";
					eng.Log(1, "connected " + host + ":" + port.ToString(CultureInfo.InvariantCulture) + " via " + via);
					lock (eng.peerLock) eng.peers.Add(this);
					if (theyExt) SendExtHandshake();
					if (eng.pieces != null) {
						SendBitfield();
						SendInterested();
						SendUnchoke();
					}
					lastRecv = DateTime.UtcNow;
					byte[] lenBuf = new byte[4];
					while (eng.running && !eng.paused) {
						bool readable = false;
						try {
							readable = io.PollRead(50000);
							if (!readable && io.Available > 0) readable = true;
						} catch { break; }
						if (!readable) {
							Pump();
							if ((DateTime.UtcNow - lastRecv).TotalSeconds > 180) break;
							continue;
						}
						if (io.Available == 0) {
							if (!io.PollRead(0) || io.Available == 0) break;
						}
						if (!ReadExact(lenBuf, 0, 4, 20000)) break;
						int mlen = Bt.R32(lenBuf, 0);
						if (mlen == 0) { lastRecv = DateTime.UtcNow; continue; }
						if (mlen < 0 || mlen > 262144) break;
						byte[] msg = new byte[mlen];
						if (!ReadExact(msg, 0, mlen, 20000)) break;
						lastRecv = DateTime.UtcNow;
						Handle(msg);
						Pump();
					}
				} catch (Exception ex) {
					eng.Log(3, "peer " + host + ":" + port.ToString(CultureInfo.InvariantCulture) + " " + ex.Message);
				} finally {
					Cleanup();
				}
			}

			public void Kill() {
				try { if (io != null) io.Close(); } catch { }
				try { if (tcp != null) tcp.Close(); } catch { }
			}

			public void SendHavePublic(int piece) {
				try { SendHave(piece); } catch { }
			}

			public void OnEngineHasInfo() {
				try {
					their = new BitArray(Math.Max(eng.meta.PieceCount, 0));
					theyHave = 0;
					theySeed = false;
					if (pendingBitfield != null) ApplyBitfield(pendingBitfield);
					pendingBitfield = null;
					for (int i = 0; i < pendingHaves.Count; i++) {
						int idx = pendingHaves[i];
						if (idx >= 0 && idx < their.Length && !their[idx]) {
							their[idx] = true;
							theyHave++;
							if (eng.pieces != null) eng.pieces.AddAvailOne(idx);
						}
					}
					if (eng.meta != null && eng.meta.PieceCount > 0 && theyHave >= eng.meta.PieceCount) theySeed = true;
					pendingHaves.Clear();
					SendBitfield();
					SendInterested();
					SendUnchoke();
					if (theyExt) SendExtHandshake();
				} catch { }
			}

			bool Connect() {
				if (io != null) return Handshake();
				if (incoming && tcp != null) {
					TcpPeerIo tio = new TcpPeerIo(tcp);
					if (!tio.AcceptMseOrPlain(eng.infoHash, eng.settings.EnableEncrypt)) return false;
					io = tio;
					return Handshake();
				}
				TcpPeerIo dio = TcpPeerIo.Dial(host, port, 4000);
				if (dio != null) {
					if (eng.settings.EnableEncrypt) {
						if (dio.TryMseOutgoing(eng.infoHash)) {
							io = dio;
							return Handshake();
						}
						dio.Close();
						dio = TcpPeerIo.Dial(host, port, 4000);
					}
					if (dio != null) {
						io = dio;
						return Handshake();
					}
				}
				if (Session.Utp != null && eng.settings.EnableUtp) {
					try {
						UtpConn uc = Session.Utp.Connect(host, port, 2000);
						if (uc != null) {
							io = new UtpPeerIo(uc);
							return Handshake();
						}
					} catch { }
				}
				return false;
			}

			bool Handshake() {
				byte[] hs = new byte[68];
				hs[0] = 19;
				byte[] proto = Encoding.ASCII.GetBytes("BitTorrent protocol");
				Buffer.BlockCopy(proto, 0, hs, 1, 19);
				hs[25] = (byte)(hs[25] | 0x10);
				Buffer.BlockCopy(eng.infoHash, 0, hs, 28, 20);
				Buffer.BlockCopy(eng.peerId, 0, hs, 48, 20);
				byte[] theirs = new byte[68];
				if (incoming) {
					if (!ReadExact(theirs, 0, 68, 15000)) return false;
					if (!CheckHs(theirs)) return false;
					WriteAll(hs);
				} else {
					WriteAll(hs);
					if (!ReadExact(theirs, 0, 68, 15000)) return false;
					if (!CheckHs(theirs)) return false;
				}
				theyExt = (theirs[25] & 0x10) != 0;
				lastRecv = DateTime.UtcNow;
				lastSend = DateTime.UtcNow;
				int pc = (eng.meta != null) ? eng.meta.PieceCount : 0;
				their = new BitArray(Math.Max(pc, 0));
				return true;
			}

			bool CheckHs(byte[] theirs) {
				if (theirs[0] != 19) return false;
				if (Encoding.ASCII.GetString(theirs, 1, 19) != "BitTorrent protocol") return false;
				for (int i = 0; i < 20; i++) if (theirs[28 + i] != eng.infoHash[i]) return false;
				return true;
			}

			void WriteAll(byte[] msg) {
				if (msg == null || io == null) return;
				lock (wlock) {
					io.Write(msg, msg.Length);
					lastSend = DateTime.UtcNow;
				}
			}

			bool ReadExact(byte[] buf, int off, int n, int timeoutMs) {
				if (io == null) return false;
				return io.ReadExact(buf, off, n, timeoutMs);
			}

			void SendInterested() {
				byte[] msg = new byte[5];
				Bt.W32(msg, 0, 1);
				msg[4] = 2;
				WriteAll(msg);
			}
			void SendUnchoke() {
				byte[] msg = new byte[5];
				Bt.W32(msg, 0, 1);
				msg[4] = 1;
				WriteAll(msg);
			}
			void SendHave(int piece) {
				byte[] msg = new byte[9];
				Bt.W32(msg, 0, 5);
				msg[4] = 4;
				Bt.W32(msg, 5, piece);
				WriteAll(msg);
			}
			void SendExt(int extId, byte[] payload) {
				byte[] msg = new byte[6 + payload.Length];
				Bt.W32(msg, 0, 2 + payload.Length);
				msg[4] = 20;
				msg[5] = (byte)extId;
				Buffer.BlockCopy(payload, 0, msg, 6, payload.Length);
				WriteAll(msg);
			}

			void SendExtHandshake() {
				Dictionary<string, Be> m = new Dictionary<string, Be>();
				m["ut_metadata"] = Be.Int(1);
				m["ut_pex"] = Be.Int(2);
				Dictionary<string, Be> root = new Dictionary<string, Be>();
				root["m"] = Be.FromDict(m);
				if (eng.boundPort > 0) root["p"] = Be.Int(eng.boundPort);
				root["v"] = Be.Blob(Encoding.UTF8.GetBytes("PowerTorrent/1.2"));
				if (eng.settings.EnableEncrypt) root["e"] = Be.Int(1);
				if (eng.rawInfo != null) root["metadata_size"] = Be.Int(eng.rawInfo.Length);
				SendExt(0, Benc.Encode(Be.FromDict(root)));
			}

			void SendMetaRequest(int index) {
				if (theirUtMeta <= 0) return;
				Dictionary<string, Be> d = new Dictionary<string, Be>();
				d["msg_type"] = Be.Int(0);
				d["piece"] = Be.Int(index);
				SendExt(theirUtMeta, Benc.Encode(Be.FromDict(d)));
			}

			void ServeMetaPiece(int index) {
				if (theirUtMeta <= 0) return;
				byte[] data = eng.MetaPieceBytes(index);
				if (data == null) {
					Dictionary<string, Be> rej = new Dictionary<string, Be>();
					rej["msg_type"] = Be.Int(2);
					rej["piece"] = Be.Int(index);
					SendExt(theirUtMeta, Benc.Encode(Be.FromDict(rej)));
					return;
				}
				Dictionary<string, Be> d = new Dictionary<string, Be>();
				d["msg_type"] = Be.Int(1);
				d["piece"] = Be.Int(index);
				d["total_size"] = Be.Int(eng.rawInfo.Length);
				byte[] hdr = Benc.Encode(Be.FromDict(d));
				byte[] payload = new byte[hdr.Length + data.Length];
				Buffer.BlockCopy(hdr, 0, payload, 0, hdr.Length);
				Buffer.BlockCopy(data, 0, payload, hdr.Length, data.Length);
				SendExt(theirUtMeta, payload);
			}

			void ApplyBitfield(byte[] bf) {
				if (eng.pieces == null || their == null) return;
				int bits = bf.Length;
				if (addedAvail) eng.pieces.SubAvail(their);
				int pc = eng.meta.PieceCount;
				their = new BitArray(Math.Max(pc, 0));
				theyHave = 0;
				for (int i = 0; i < pc; i++) {
					int bi = i / 8;
					if (bi >= bits) break;
					int bit = 7 - (i % 8);
					if ((bf[bi] & (1 << bit)) != 0) {
						their[i] = true;
						theyHave++;
					}
				}
				theySeed = pc > 0 && theyHave >= pc;
				eng.pieces.AddAvail(their);
				addedAvail = true;
			}

			void SendBitfield() {
				if (eng.pieces == null) return;
				byte[] bf = eng.pieces.MakeBitfield();
				bool any = false;
				for (int i = 0; i < bf.Length; i++) if (bf[i] != 0) { any = true; break; }
				if (!any) return;
				byte[] msg = new byte[5 + bf.Length];
				Bt.W32(msg, 0, 1 + bf.Length);
				msg[4] = 5;
				Buffer.BlockCopy(bf, 0, msg, 5, bf.Length);
				WriteAll(msg);
			}
			void SendRequest(int piece, int begin, int len) {
				byte[] msg = new byte[17];
				Bt.W32(msg, 0, 13);
				msg[4] = 6;
				Bt.W32(msg, 5, piece);
				Bt.W32(msg, 9, begin);
				Bt.W32(msg, 13, len);
				WriteAll(msg);
			}
			void SendKeepAlive() {
				WriteAll(new byte[4]);
			}
			void SendPieceMsg(int index, int begin, byte[] data) {
				byte[] msg = new byte[13 + data.Length];
				Bt.W32(msg, 0, 9 + data.Length);
				msg[4] = 7;
				Bt.W32(msg, 5, index);
				Bt.W32(msg, 9, begin);
				Buffer.BlockCopy(data, 0, msg, 13, data.Length);
				WriteAll(msg);
				eng.AddSessionUp(data.Length);
			}

			void Handle(byte[] msg) {
				if (msg.Length < 1) return;
				int id = msg[0];
				if (id == 0) {
					amChoked = true;
					DropClaims();
				} else if (id == 1) {
					amChoked = false;
				} else if (id == 2) {
					SendUnchoke();
				} else if (id == 4 && msg.Length >= 5) {
					int idx = Bt.R32(msg, 1);
					if (eng.pieces == null) {
						pendingHaves.Add(idx);
					} else if (their != null && idx >= 0 && idx < their.Length && !their[idx]) {
						their[idx] = true;
						theyHave++;
						if (eng.meta != null && theyHave >= eng.meta.PieceCount && eng.meta.PieceCount > 0) theySeed = true;
						eng.pieces.AddAvailOne(idx);
					}
				} else if (id == 5) {
					int bits = msg.Length - 1;
					byte[] bf = new byte[bits];
					Buffer.BlockCopy(msg, 1, bf, 0, bits);
					if (eng.pieces == null) pendingBitfield = bf;
					else {
						ApplyBitfield(bf);
						if (eng.pieces.PeerHasSomethingWeNeed(their)) SendInterested();
					}
				} else if (id == 6 && msg.Length >= 13) {
					if (eng.pieces == null) return;
					int idx = Bt.R32(msg, 1);
					int begin = Bt.R32(msg, 5);
					int len = Bt.R32(msg, 9);
					if (len > 16384 || len <= 0) return;
					byte[] data = eng.pieces.ReadBlock(idx, begin, len);
					if (data != null) SendPieceMsg(idx, begin, data);
				} else if (id == 20 && msg.Length >= 2) {
					HandleExt(msg);
				} else if (id == 7 && msg.Length >= 9) {
					int idx = Bt.R32(msg, 1);
					int begin = Bt.R32(msg, 5);
					int dlen = msg.Length - 9;
					bool match = false;
					for (int i = 0; i < claimsPiece.Count; i++) {
						if (claimsPiece[i] == idx && claimsBegin[i] == begin) {
							claimsPiece.RemoveAt(i);
							claimsBegin.RemoveAt(i);
							claimAt.RemoveAt(i);
							match = true;
							break;
						}
					}
					if (!match) return;
					if (eng.pieces == null) return;
					int stored = eng.pieces.Submit(idx, begin, msg, 9, dlen);
					if (stored == 0) eng.pieces.Unclaim(idx, begin);
					else if (stored == 2) {
						eng.Log(2, "piece " + idx.ToString(CultureInfo.InvariantCulture) + " verified");
						eng.BroadcastHave(idx);
					}
				}
			}

			void HandleExt(byte[] msg) {
				int ext = msg[1];
				if (ext == 0) {
					int consumed;
					Be d = Benc.DecodeAt(msg, 2, out consumed);
					if (d == null || d.Dict == null) return;
					Be m = d.Get("m");
					if (m != null && m.Dict != null) {
						theirUtMeta = (int)m.GetInt("ut_metadata", 0);
						theirUtPex = (int)m.GetInt("ut_pex", 0);
					}
					int msz = (int)d.GetInt("metadata_size", 0);
					if (msz > 0 && !eng.infoReady) eng.OfferMetaSize(msz);
				} else if (ext == 1) {
					int consumed;
					Be d = Benc.DecodeAt(msg, 2, out consumed);
					if (d == null || d.Dict == null) return;
					int mtype = (int)d.GetInt("msg_type", -1);
					int piece = (int)d.GetInt("piece", -1);
					if (mtype == 0) {
						ServeMetaPiece(piece);
					} else if (mtype == 1) {
						int rest = msg.Length - 2 - consumed;
						if (rest < 0) return;
						byte[] data = new byte[rest];
						if (rest > 0) Buffer.BlockCopy(msg, 2 + consumed, data, 0, rest);
						int ts = (int)d.GetInt("total_size", 0);
						if (ts > 0) eng.OfferMetaSize(ts);
						lastMetaIdx = -1;
						eng.OfferMetaPiece(piece, data);
					} else if (mtype == 2) {
						lastMetaIdx = -1;
					}
				} else if (ext == 2) {
					int consumed;
					Be d = Benc.DecodeAt(msg, 2, out consumed);
					if (d == null || d.Dict == null) return;
					Be added = d.Get("added");
					if (added != null && added.Bytes != null) {
						List<string> tmp = new List<string>();
						Bt.AddCompactPeers(added.Bytes, tmp);
						for (int i = 0; i < tmp.Count; i++) eng.RememberPeer(tmp[i]);
						if (tmp.Count > 0) eng.Log(2, "PEX +" + tmp.Count.ToString(CultureInfo.InvariantCulture) + " from " + host);
					}
				}
			}

			void Pump() {
				if (!eng.running || eng.paused) return;
				DateTime now = DateTime.UtcNow;
				if ((now - lastSend).TotalSeconds > 100) {
					try { SendKeepAlive(); } catch { }
				}
				if (eng.pieces == null) {
					if (theirUtMeta > 0 && !eng.infoReady) {
						if (lastMetaIdx < 0 || (now - lastMetaAt).TotalSeconds > 8) {
							int idx = eng.NextMetaPiece();
							if (idx >= 0) {
								lastMetaIdx = idx;
								lastMetaAt = now;
								try { SendMetaRequest(idx); } catch { }
							}
						}
					}
					return;
				}
				int claimSec = eng.pieces.IsEndgame() ? 6 : 15;
				for (int i = claimsPiece.Count - 1; i >= 0; i--) {
					if ((now - claimAt[i]).TotalSeconds > claimSec) {
						eng.pieces.Unclaim(claimsPiece[i], claimsBegin[i]);
						claimsPiece.RemoveAt(i);
						claimsBegin.RemoveAt(i);
						claimAt.RemoveAt(i);
					}
				}
				if (amChoked) return;
				bool endgame = eng.pieces.IsEndgame();
				while (claimsPiece.Count < 48) {
					int p, b, l;
					if (!eng.pieces.TryClaim(their, eng.settings.Sequential, endgame, out p, out b, out l)) break;
					claimsPiece.Add(p);
					claimsBegin.Add(b);
					claimAt.Add(DateTime.UtcNow);
					try { SendRequest(p, b, l); }
					catch {
						eng.pieces.Unclaim(p, b);
						claimsPiece.RemoveAt(claimsPiece.Count - 1);
						claimsBegin.RemoveAt(claimsBegin.Count - 1);
						claimAt.RemoveAt(claimAt.Count - 1);
						break;
					}
				}
			}

			void DropClaims() {
				if (eng.pieces == null) {
					claimsPiece.Clear();
					claimsBegin.Clear();
					claimAt.Clear();
					return;
				}
				for (int i = 0; i < claimsPiece.Count; i++) eng.pieces.Unclaim(claimsPiece[i], claimsBegin[i]);
				claimsPiece.Clear();
				claimsBegin.Clear();
				claimAt.Clear();
			}

			void Cleanup() {
				try { DropClaims(); } catch { }
				if (addedAvail && eng.pieces != null) {
					try { eng.pieces.SubAvail(their); } catch { }
					addedAvail = false;
				}
				lock (eng.peerLock) eng.peers.Remove(this);
				try { if (io != null) io.Close(); } catch { }
				try { if (tcp != null) tcp.Close(); } catch { }
			}
		}

		public Engine(EngineSettings s) {
			if (s == null) throw new ArgumentNullException("s");
			settings = s;
			if (settings.MaxPeers <= 0) settings.MaxPeers = 80;
			if (settings.ListenPort <= 0) settings.ListenPort = 6881;
			logLevel = settings.LogLevel;
			peerId = Bt.MakePeerId();

			bool isMagnet = !string.IsNullOrEmpty(s.MagnetUri);
			if (isMagnet) {
				MagnetLink mag = MagnetLink.Parse(s.MagnetUri);
				infoHash = mag.InfoHash;
				v2Hash = mag.V2Hash;
				v2Only = mag.V2Only;
				magnetTrackers = mag.Trackers;
				magnetWebseeds = mag.Webseeds;
				meta = Meta.Stub(mag.DisplayName, mag.InfoHash, mag.Trackers, mag.Webseeds);
				infoReady = false;
				status.State = "Idle";
				status.Name = meta.Name;
				return;
			}

			if (string.IsNullOrEmpty(s.TorrentPath) || !File.Exists(s.TorrentPath))
				throw new FileNotFoundException("torrent not found", s.TorrentPath);
			byte[] torrentBytes = File.ReadAllBytes(s.TorrentPath);
			meta = Meta.Load(torrentBytes, s.SavePath);
			infoHash = meta.InfoHash;
			v2Hash = meta.V2Hash;
			v2Only = meta.V2 && meta.PieceHashes == null;
			rawInfo = meta.RawInfo;
			pieces = new PieceMgr(this, meta);
			infoReady = true;
			status.State = "Idle";
			status.Name = meta.Name;
		}

		public bool IsRunning {
			get {
				if (!running) return false;
				string st;
				lock (statusLock) st = status.State;
				if (st == "Error" || st == "Stopped" || st == "Complete") return false;
				return true;
			}
		}

		public static string Fmt(long n) {
			double v = (double)n;
			string u = "B";
			if (v >= 1024) { v /= 1024; u = "KB"; }
			if (v >= 1024) { v /= 1024; u = "MB"; }
			if (v >= 1024) { v /= 1024; u = "GB"; }
			if (v >= 1024) { v /= 1024; u = "TB"; }
			return v.ToString("0.00", CultureInfo.InvariantCulture) + " " + u;
		}

		public TorrentInfo GetInfo() {
			TorrentInfo t = new TorrentInfo();
			t.Name = meta != null ? meta.Name : "";
			t.Comment = meta != null ? (meta.Comment ?? "") : "";
			t.CreatedBy = meta != null ? (meta.CreatedBy ?? "") : "";
			t.InfoHashHex = meta != null ? meta.InfoHashHex : "";
			t.TotalSize = meta != null ? meta.TotalSize : 0;
			t.PieceLength = meta != null ? meta.PieceLength : 0;
			t.PieceCount = meta != null ? meta.PieceCount : 0;
			t.FileCount = (meta != null && meta.Files != null) ? meta.Files.Count : 0;
			t.IsMulti = meta != null && meta.IsMulti;
			t.SavePath = settings != null && settings.SavePath != null ? settings.SavePath : "";
			t.Trackers = (meta != null) ? meta.Trackers.ToArray() : new string[0];
			t.Webseeds = (meta != null) ? meta.Webseeds.ToArray() : new string[0];
			int fc = t.FileCount;
			t.Files = new string[fc];
			t.FileRows = new FileRow[fc];
			for (int i = 0; i < fc; i++) {
				FileRow fr = new FileRow();
				fr.Name = meta.Files[i].RelPath ?? "";
				fr.SizeText = Fmt(meta.Files[i].Length);
				t.FileRows[i] = fr;
				t.Files[i] = fr.Name + "	(" + fr.SizeText + ")";
			}
			if (pieces != null) pieces.FillFileProgress(t.FileRows);
			return t;
		}

		public void UpdateFileProgress(FileRow[] rows) {
			if (pieces != null) pieces.FillFileProgress(rows);
		}

		void NoteSwarm(int seeds) {
			if (seeds > trackerSeeds) trackerSeeds = seeds;
		}

		public EngineSettings Settings { get { return settings; } }
		public bool IsPaused { get { return paused; } }
		internal byte[] InfoHashBytes { get { return infoHash; } }
		internal int ActivePeerThreads { get { return activePeerThreads; } }
		internal bool KeepGoing { get { return running; } }

		internal void RunIncoming(PeerIo io) {
			Interlocked.Increment(ref activePeerThreads);
			try {
				PeerWorker w = new PeerWorker(this, io);
				w.Run();
			} finally {
				Interlocked.Decrement(ref activePeerThreads);
			}
		}

		void ZeroRates() {
			downBps = 0;
			upBps = 0;
			lastDl = Interlocked.Read(ref sessionDown);
			lastUl = Interlocked.Read(ref sessionUp);
			lastSp = DateTime.UtcNow;
		}

		public void Pause() {
			paused = true;
			ZeroRates();
			PeerWorker[] snap;
			lock (peerLock) snap = peers.ToArray();
			for (int i = 0; i < snap.Length; i++) snap[i].Kill();
			lock (statusLock) status.State = "Paused";
			Log(1, "paused");
		}

		public void Resume() {
			paused = false;
			lastDl = Interlocked.Read(ref sessionDown);
			lastUl = Interlocked.Read(ref sessionUp);
			lastSp = DateTime.UtcNow;
			if (!running) {
				Start();
				return;
			}
			lock (statusLock) {
				if (status.State == "Paused") {
					if (!infoReady) status.State = "Metadata";
					else if (pieces != null && pieces.IsComplete)
						status.State = settings.SeedAfterComplete ? "Seeding" : "Complete";
					else status.State = "Downloading";
				}
			}
			Log(1, "resumed");
		}

		public void Start() {
			if (running) return;
			if (!Session.Register(this)) {
				lock (statusLock) {
					status.State = "Error";
					status.ErrorMessage = "session torrent limit (" + Session.MaxTorrents.ToString(CultureInfo.InvariantCulture) + ")";
				}
				return;
			}
			sessionReg = true;
			running = true;
			coordThread = new Thread(Coordinator);
			coordThread.IsBackground = true;
			coordThread.Name = "PowerTorrent";
			coordThread.Start();
		}

		public void ApplyLiveSettings() {
			if (settings.MaxPeers <= 0) settings.MaxPeers = 80;
			if (settings.ListenPort <= 0) settings.ListenPort = 6881;
			if (!running) return;
			if (settings.EnableDht) {
				Thread t = dhtThread;
				if (t == null || !t.IsAlive) {
					dhtThread = new Thread(DhtRun);
					dhtThread.IsBackground = true;
					dhtThread.Start();
					Log(1, "DHT enabled");
				}
			}
			Session.EnsureListen(settings.ListenPort, settings.EnableUtp);
			if (boundPort <= 0) boundPort = Session.BoundPort;
		}

		public void Stop() {
			paused = false;
			running = false;
			ZeroRates();
			PeerWorker[] snap;
			lock (peerLock) snap = peers.ToArray();
			for (int i = 0; i < snap.Length; i++) snap[i].Kill();
			if (startedAnnounced) {
				try { AnnounceAll("stopped"); } catch { }
			}
			if (coordThread != null && Thread.CurrentThread != coordThread) {
				try { coordThread.Join(3000); } catch { }
			}
			if (pieces != null) pieces.Close();
			if (sessionReg) {
				Session.Unregister(this);
				sessionReg = false;
			}
			ZeroRates();
			lock (statusLock) {
				if (status.State != "Complete" && status.State != "Error") status.State = "Stopped";
			}
		}

		public void DeleteDownloadedFiles() {
			if (meta == null || meta.Files == null) return;
			for (int i = 0; i < meta.Files.Count; i++) {
				string p = meta.Files[i].Path;
				if (string.IsNullOrEmpty(p)) continue;
				try { if (File.Exists(p)) File.Delete(p); } catch (Exception ex) { Log(1, "delete failed: " + ex.Message); }
			}
			try {
				if (settings != null && !string.IsNullOrEmpty(settings.SavePath) && meta.Name != null) {
					string tp = Path.Combine(settings.SavePath, meta.Name + ".torrent");
					if (File.Exists(tp)) File.Delete(tp);
				}
			} catch { }
			if (meta.IsMulti && settings != null && !string.IsNullOrEmpty(settings.SavePath) && !string.IsNullOrEmpty(meta.Name)) {
				try {
					string saveRoot = Path.GetFullPath(settings.SavePath).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
					string root = Path.GetFullPath(Path.Combine(settings.SavePath, meta.Name));
					string prefix = saveRoot + Path.DirectorySeparatorChar;
					if (Directory.Exists(root) && root.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)
						&& !string.Equals(root, saveRoot, StringComparison.OrdinalIgnoreCase))
						Directory.Delete(root, true);
				} catch (Exception ex) { Log(1, "delete folder failed: " + ex.Message); }
			}
		}

		public EngineStatus GetStatus() {
			EngineStatus s = new EngineStatus();
			int dc = 0, tot = 0;
			long ver = 0, totb = 0;
			if (pieces != null) pieces.Snapshot(out dc, out tot, out ver, out totb);
			lock (statusLock) {
				s.State = status.State;
				s.ErrorMessage = status.ErrorMessage;
			}
			s.Name = meta != null ? meta.Name : "";
			s.InfoHashHex = meta != null ? meta.InfoHashHex : "";
			s.Downloaded = ver;
			s.Uploaded = Interlocked.Read(ref sessionUp);
			s.TotalSize = meta != null ? meta.TotalSize : 0;
			if (s.State == "Metadata" || (!infoReady && pieces == null)) {
				int got, totMd;
				lock (metaLock) {
					got = mdGot;
					totMd = mdHave != null ? mdHave.Length : 0;
				}
				s.State = "Metadata";
				s.PiecesDone = got;
				s.PiecesTotal = totMd;
				s.ProgressPercent = totMd > 0 ? (100.0 * got / totMd) : 0;
				s.Eta = "metadata";
			} else if (s.State == "Hashing") {
				int hpDone, hpTot;
				lock (statusLock) {
					hpDone = status.PiecesDone;
					hpTot = status.PiecesTotal;
				}
				s.PiecesDone = hpDone;
				s.PiecesTotal = hpTot > 0 ? hpTot : tot;
				s.ProgressPercent = s.PiecesTotal > 0 ? (100.0 * hpDone / s.PiecesTotal) : 0;
				s.Eta = "checking";
			} else {
				s.ProgressPercent = s.TotalSize > 0 ? (100.0 * ver / s.TotalSize) : 0;
				s.PiecesDone = dc;
				s.PiecesTotal = tot;
				if (downBps > 64 && ver < s.TotalSize) {
					int secI = (int)((s.TotalSize - ver) / downBps);
					if (secI < 0) secI = 0;
					s.Eta = string.Format(CultureInfo.InvariantCulture, "{0:00}:{1:00}:{2:00}", secI / 3600, (secI / 60) % 60, secI % 60);
				} else {
					s.Eta = "--";
				}
			}
			int seedN = 0;
			lock (peerLock) {
				s.PeersConnected = peers.Count;
				for (int i = 0; i < peers.Count; i++) if (peers[i].IsSeed) seedN++;
			}
			s.SeedsConnected = seedN;
			int ts = trackerSeeds;
			s.SeedsKnown = ts > seedN ? ts : seedN;
			lock (poolLock) s.PeersKnown = seen.Count;
			s.ListenPort = boundPort;
			s.Availability = pieces != null ? pieces.Availability() : 0;
			lock (logLock) s.LogLines = logs.ToArray();
			if (paused && s.State != "Stopped" && s.State != "Error" && s.State != "Complete")
				s.State = "Paused";
			bool halt = paused || !running || s.State == "Stopped" || s.State == "Paused" || s.State == "Error" || s.State == "Complete" || s.State == "VPN";
			if (halt) {
				s.DownBytesPerSec = 0;
				s.UpBytesPerSec = 0;
				if (s.State == "Paused" || s.State == "Stopped" || s.State == "Complete" || s.State == "Error" || s.State == "VPN")
					s.Eta = "--";
			} else {
				UpdateSpeed();
				s.DownBytesPerSec = downBps;
				s.UpBytesPerSec = upBps;
			}
			return s;
		}

		public static string SelfTest() {
			try {
				Be a = Benc.Decode(Encoding.ASCII.GetBytes("i42e"));
				if (a.Kind != 0 || a.I != 42) return "int";
				Be b = Benc.Decode(Encoding.ASCII.GetBytes("4:spam"));
				if (Encoding.ASCII.GetString(b.Bytes) != "spam") return "str";
				Be c = Benc.Decode(Encoding.ASCII.GetBytes("le"));
				if (c.List == null || c.List.Count != 0) return "elist";
				Be d = Benc.Decode(Encoding.ASCII.GetBytes("de"));
				if (d.Dict == null || d.Dict.Count != 0) return "edict";
				Be e = Benc.Decode(Encoding.ASCII.GetBytes("d3:foo3:bare"));
				if (e.Str("foo") != "bar") return "dict";
				byte[] rt = Benc.Encode(e);
				Be e2 = Benc.Decode(rt);
				if (e2.Str("foo") != "bar") return "roundtrip";

				byte[] torrent = Encoding.ASCII.GetBytes("d8:announce15:http://t.com:804:infod6:lengthi4e4:name4:test12:piece lengthi16384e6:pieces20:01234567890123456789ee");
				byte[] info = Benc.SliceDictValue(torrent, "info");
				if (info == null || info[0] != (byte)'d') return "slice";
				Be root = Benc.Decode(torrent);
				if (root.Get("info") == null) return "parse torrent";
				if (root.Get("info").GetInt("length", 0) != 4) return "info length";

				byte[] buf4 = new byte[4];
				Bt.W32(buf4, 0, 0x01020304);
				if (buf4[0] != 1 || buf4[1] != 2 || buf4[2] != 3 || buf4[3] != 4) return "w32";
				if (Bt.R32(buf4, 0) != 0x01020304) return "r32";

				byte[] buf8 = new byte[8];
				Bt.W64(buf8, 0, 0x41727101980L);
				if (buf8[2] != 0x04 || buf8[3] != 0x17 || buf8[7] != 0x80) return "w64-magic";
				if (Bt.R64(buf8, 0) != 0x41727101980L) return "r64";

				string enc = Bt.UrlEnc(new byte[] { 0x00, 0xAB, 0xFF });
				if (enc != "%00%AB%FF") return "urlenc " + enc;

				List<string> peers = new List<string>();
				Bt.AddCompactPeers(new byte[] { 1, 2, 3, 4, 0x1A, 0xE1 }, peers);
				if (peers.Count != 1 || peers[0] != "1.2.3.4:6881") return "compact " + (peers.Count > 0 ? peers[0] : "none");

				byte[] empty = Benc.Encode(Be.FromDict(new Dictionary<string, Be>()));
				if (empty.Length != 2 || empty[0] != (byte)'d' || empty[1] != (byte)'e') return "enc-de";

				int consumed;
				Be da = Benc.DecodeAt(Encoding.ASCII.GetBytes("i42eMORE"), 0, out consumed);
				if (da.I != 42 || consumed != 4) return "decodeat";

				MagnetLink mag = MagnetLink.Parse("magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=Hello%20World&tr=udp%3A%2F%2Ft.example.com%3A80");
				if (mag.InfoHashHex != "0123456789abcdef0123456789abcdef01234567") return "magnet-hex";
				if (mag.DisplayName != "Hello World") return "magnet-dn";
				if (mag.Trackers.Count != 1 || mag.Trackers[0] != "udp://t.example.com:80") return "magnet-tr";

				byte[] z = MagnetLink.FromBase32("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
				if (z == null || z.Length != 20) return "b32-len";
				for (int i = 0; i < 20; i++) if (z[i] != 0) return "b32-zero";

				byte[] h = MagnetLink.ParseInfoHash("0123456789ABCDEF0123456789ABCDEF01234567");
				if (h == null || h[0] != 0x01 || h[19] != 0x67) return "parse-hash";

				MagnetLink mag2 = MagnetLink.Parse("magnet:?xt=urn:btmh:1220000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f");
				if (!mag2.V2Only || mag2.V2Hash == null || mag2.V2Hash.Length != 32) return "magnet-v2";
				if (mag2.InfoHash[0] != 0x00 || mag2.InfoHash[1] != 0x01 || mag2.V2Hash[31] != 0x1f) return "magnet-v2-trunc";

				Rc4 rc = new Rc4(Encoding.ASCII.GetBytes("Key"));
				byte[] pt = Encoding.ASCII.GetBytes("Plaintext");
				rc.Crypt(pt, 0, pt.Length);
				string rcHex = BitConverter.ToString(pt).Replace("-", "");
				if (rcHex != "BBF316E8D940AF0AD3") return "rc4 " + rcHex;

				BigInteger two = new BigInteger(2);
				byte[] pub = Crypto.DhPub(two);
				if (pub.Length != 96 || pub[95] != 4) return "dh-pub";
				byte[] sec = Crypto.DhSecret(pub, two);
				if (sec[95] != 16) return "dh-sec";

				byte[] leaf = new byte[16384];
				byte[] mroot = Crypto.MerklePiece(leaf, leaf.Length);
				if (mroot == null || mroot.Length != 32) return "merkle";
				int plim = Session.PeerLimit(null, 80);
				if (plim < 6 || plim > Session.GlobalMaxPeers) return "session-peer-limit";
				if (Session.TorrentCount != 0) return "session-count";
				List<Engine> batch = new List<Engine>();
				try {
					for (int i = 0; i < 50; i++) {
						EngineSettings es = new EngineSettings();
						es.MagnetUri = "magnet:?xt=urn:btih:" + i.ToString("x8", CultureInfo.InvariantCulture).PadLeft(40, '0');
						es.SavePath = Path.GetTempPath();
						es.MaxPeers = 80;
						es.ListenPort = 6881;
						Engine en = new Engine(es);
						if (!Session.Register(en)) return "session-reg-50 " + i.ToString(CultureInfo.InvariantCulture);
						batch.Add(en);
					}
					if (Session.TorrentCount != 50) return "session-count-50";
					int share = Session.PeerLimit(batch[0], 80);
					if (share != 10) return "session-share-50 " + share.ToString(CultureInfo.InvariantCulture);
					EngineSettings extraS = new EngineSettings();
					extraS.MagnetUri = batch[0].GetInfo().InfoHashHex.Length == 40
						? "magnet:?xt=urn:btih:" + batch[0].GetInfo().InfoHashHex
						: "magnet:?xt=urn:btih:ffffffffffffffffffffffffffffffffffffffff";
					extraS.SavePath = Path.GetTempPath();
					Engine dup = new Engine(extraS);
					if (Session.Register(dup)) return "session-dup";
				} finally {
					for (int i = 0; i < batch.Count; i++) Session.Unregister(batch[i]);
				}
				if (Session.TorrentCount != 0) return "session-cleanup";
				string vpnFail = VpnHub.SelfCheck();
				if (vpnFail != null) return "vpn-" + vpnFail;
				return null;
			} catch (Exception ex) {
				return ex.ToString();
			}
		}

		void AddSessionDown(int n) { Interlocked.Add(ref sessionDown, n); }
		void AddSessionUp(int n) { Interlocked.Add(ref sessionUp, n); }

		void Log(int level, string msg) {
			if (level > logLevel) return;
			string line = DateTime.Now.ToString("HH:mm:ss", CultureInfo.InvariantCulture) + "  " + msg;
			lock (logLock) {
				logs.Add(line);
				while (logs.Count > 15) logs.RemoveAt(0);
			}
		}

		void OnHashProgress(int cur, int tot) {
			lock (statusLock) {
				status.State = "Hashing";
				status.PiecesDone = cur;
				status.PiecesTotal = tot;
			}
		}

		void BroadcastHave(int piece) {
			PeerWorker[] snap;
			lock (peerLock) snap = peers.ToArray();
			for (int i = 0; i < snap.Length; i++) {
				try { snap[i].SendHavePublic(piece); } catch { }
			}
		}

		bool OfferMetaSize(int size) {
			if (size <= 0 || size > 8 * 1024 * 1024) return false;
			lock (metaLock) {
				if (mdSize < 0) {
					mdSize = size;
					int n = (size + 16383) / 16384;
					mdPieces = new byte[n][];
					mdHave = new bool[n];
					mdGot = 0;
					Log(1, "metadata size " + size.ToString(CultureInfo.InvariantCulture) + " bytes (" + n.ToString(CultureInfo.InvariantCulture) + " piece(s))");
					return true;
				}
				return mdSize == size;
			}
		}

		int NextMetaPiece() {
			lock (metaLock) {
				if (mdHave == null) return -1;
				for (int i = 0; i < mdHave.Length; i++) if (!mdHave[i]) return i;
				return -1;
			}
		}

		byte[] MetaPieceBytes(int index) {
			lock (metaLock) {
				if (rawInfo == null) return null;
				int sz = rawInfo.Length;
				int n = (sz + 16383) / 16384;
				if (index < 0 || index >= n) return null;
				int off = index * 16384;
				int len = Math.Min(16384, sz - off);
				byte[] b = new byte[len];
				Buffer.BlockCopy(rawInfo, off, b, 0, len);
				return b;
			}
		}

		void OfferMetaPiece(int index, byte[] data) {
			byte[] assembled = null;
			lock (metaLock) {
				if (infoReady || mdHave == null || index < 0 || index >= mdHave.Length) return;
				if (mdHave[index]) return;
				int expect = (index == mdHave.Length - 1) ? (mdSize - index * 16384) : 16384;
				if (data == null || data.Length != expect) return;
				mdPieces[index] = data;
				mdHave[index] = true;
				mdGot++;
				if (mdGot < mdHave.Length) {
					Log(2, "metadata piece " + index.ToString(CultureInfo.InvariantCulture) + " (" + mdGot.ToString(CultureInfo.InvariantCulture) + "/" + mdHave.Length.ToString(CultureInfo.InvariantCulture) + ")");
					return;
				}
				assembled = new byte[mdSize];
				int o = 0;
				for (int i = 0; i < mdPieces.Length; i++) {
					Buffer.BlockCopy(mdPieces[i], 0, assembled, o, mdPieces[i].Length);
					o += mdPieces[i].Length;
				}
			}
			if (assembled == null) return;
			byte[] hash;
			using (SHA1CryptoServiceProvider sha = new SHA1CryptoServiceProvider()) {
				hash = sha.ComputeHash(assembled);
			}
			bool hashOk = true;
			if (v2Only && v2Hash != null && v2Hash.Length == 32) {
				byte[] h256 = Crypto.Sha256All(assembled);
				for (int k = 0; k < 32; k++) if (h256[k] != v2Hash[k]) hashOk = false;
			} else {
				for (int k = 0; k < 20; k++) if (hash[k] != infoHash[k]) hashOk = false;
			}
			if (!hashOk) {
					Log(0, "metadata hash mismatch, retrying");
					lock (metaLock) {
						mdSize = -1;
						mdPieces = null;
						mdHave = null;
						mdGot = 0;
					}
					return;
			}
			fetchedInfo = assembled;
			infoReady = true;
			Log(1, "metadata received (" + assembled.Length.ToString(CultureInfo.InvariantCulture) + " bytes)");
		}

		void ApplyFetchedInfo() {
			if (fetchedInfo == null) throw new Exception("no metadata");
			Meta loaded = Meta.FromInfoBytes(fetchedInfo, settings.SavePath);
			HashSet<string> seenT = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
			for (int i = 0; i < loaded.Trackers.Count; i++) seenT.Add(loaded.Trackers[i]);
			for (int i = 0; i < magnetTrackers.Count; i++) MetaAddTracker(loaded, seenT, magnetTrackers[i]);
			for (int i = 0; i < magnetWebseeds.Count; i++) {
				if (!string.IsNullOrEmpty(magnetWebseeds[i]) && !loaded.Webseeds.Contains(magnetWebseeds[i]))
					loaded.Webseeds.Add(magnetWebseeds[i]);
			}
			meta = loaded;
			rawInfo = fetchedInfo;
			pieces = new PieceMgr(this, meta);
			status.Name = meta.Name;
			Log(1, "torrent: " + meta.Name + " (" + Fmt(meta.TotalSize) + ", " + meta.PieceCount.ToString(CultureInfo.InvariantCulture) + " pieces)");
			SaveTorrentFile();
			PeerWorker[] snap;
			lock (peerLock) snap = peers.ToArray();
			for (int i = 0; i < snap.Length; i++) {
				try { snap[i].OnEngineHasInfo(); } catch { }
			}
		}

		static void MetaAddTracker(Meta m, HashSet<string> seenT, string url) {
			if (string.IsNullOrEmpty(url)) return;
			url = url.Trim();
			if (url.Length == 0) return;
			if (!seenT.Add(url)) return;
			m.Trackers.Add(url);
		}

		void SaveTorrentFile() {
			try {
				if (rawInfo == null || meta == null) return;
				string path = Path.Combine(settings.SavePath, meta.Name + ".torrent");
				MemoryStream ms = new MemoryStream();
				ms.WriteByte((byte)'d');
				if (meta.Trackers.Count > 0) {
					WriteBencBytes(ms, Encoding.UTF8.GetBytes("announce"));
					WriteBencBytes(ms, Encoding.UTF8.GetBytes(meta.Trackers[0]));
					if (meta.Trackers.Count > 1) {
						WriteBencBytes(ms, Encoding.UTF8.GetBytes("announce-list"));
						ms.WriteByte((byte)'l');
						for (int i = 0; i < meta.Trackers.Count; i++) {
							ms.WriteByte((byte)'l');
							WriteBencBytes(ms, Encoding.UTF8.GetBytes(meta.Trackers[i]));
							ms.WriteByte((byte)'e');
						}
						ms.WriteByte((byte)'e');
					}
				}
				WriteBencBytes(ms, Encoding.UTF8.GetBytes("created by"));
				WriteBencBytes(ms, Encoding.UTF8.GetBytes("PowerTorrent/1.2"));
				WriteBencBytes(ms, Encoding.UTF8.GetBytes("info"));
				ms.Write(rawInfo, 0, rawInfo.Length);
				if (meta.Webseeds.Count > 0) {
					WriteBencBytes(ms, Encoding.UTF8.GetBytes("url-list"));
					ms.WriteByte((byte)'l');
					for (int i = 0; i < meta.Webseeds.Count; i++)
						WriteBencBytes(ms, Encoding.UTF8.GetBytes(meta.Webseeds[i]));
					ms.WriteByte((byte)'e');
				}
				ms.WriteByte((byte)'e');
				File.WriteAllBytes(path, ms.ToArray());
				Log(1, "wrote " + path);
			} catch (Exception ex) {
				Log(1, "could not save .torrent: " + ex.Message);
			}
		}

		static void WriteBencBytes(MemoryStream ms, byte[] data) {
			byte[] hdr = Encoding.ASCII.GetBytes(data.Length.ToString(CultureInfo.InvariantCulture) + ":");
			ms.Write(hdr, 0, hdr.Length);
			ms.Write(data, 0, data.Length);
		}

		void RememberPeer(string ep) {
			if (string.IsNullOrEmpty(ep)) return;
			lock (poolLock) {
				if (seen.Add(ep)) pool.Enqueue(ep);
			}
		}

		string NextPeer() {
			lock (poolLock) {
				if (pool.Count == 0) return null;
				return pool.Dequeue();
			}
		}

		void RecyclePeers() {
			lock (poolLock) {
				if (pool.Count > 0) return;
				if (seen.Count == 0) return;
				if ((DateTime.UtcNow - lastRecycle).TotalSeconds < 90) return;
				lastRecycle = DateTime.UtcNow;
				foreach (string s in seen) pool.Enqueue(s);
				Log(2, "re-queued " + seen.Count.ToString(CultureInfo.InvariantCulture) + " peers");
			}
		}

		void UpdateSpeed() {
			DateTime n = DateTime.UtcNow;
			double dt = (n - lastSp).TotalSeconds;
			if (dt < 0.12) return;
			long dl = Interlocked.Read(ref sessionDown);
			long ul = Interlocked.Read(ref sessionUp);
			double nd = (dl - lastDl) / dt;
			double nu = (ul - lastUl) / dt;
			if (downBps < 32 && nd > 0) downBps = nd;
			else downBps = downBps * 0.35 + nd * 0.65;
			if (upBps < 32 && nu > 0) upBps = nu;
			else upBps = upBps * 0.35 + nu * 0.65;
			lastDl = dl;
			lastUl = ul;
			lastSp = n;
		}

		void Coordinator() {
			try {
				try {
					ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12 | SecurityProtocolType.Tls11 | SecurityProtocolType.Tls;
				} catch { }
				ServicePointManager.DefaultConnectionLimit = 64;
				ServicePointManager.Expect100Continue = false;

				while (running && VpnHub.Blocked) {
					lock (statusLock) {
						status.State = "VPN";
						status.ErrorMessage = string.IsNullOrEmpty(VpnHub.LastError) ? "VPN down" : VpnHub.LastError;
					}
					Thread.Sleep(400);
				}
				if (!running) return;
				lock (statusLock) status.ErrorMessage = "";

				lock (statusLock) status.State = "Preparing";
				Log(1, "info hash " + meta.InfoHashHex);
				if (VpnHub.TunnelOn) Log(1, "VPN tunnel " + VpnHub.Status);
				StartListen();
				if (!string.IsNullOrEmpty(settings.ForcedPeer)) RememberPeer(settings.ForcedPeer);

				if (meta.Trackers.Count > 0) {
					lock (statusLock) status.State = infoReady ? "Announcing" : "Metadata";
					Log(1, "announcing to " + meta.Trackers.Count.ToString(CultureInfo.InvariantCulture) + " tracker(s)");
					AnnounceAll("started");
					startedAnnounced = true;
				}

				if (settings.EnableDht) {
					dhtThread = new Thread(DhtRun);
					dhtThread.IsBackground = true;
					dhtThread.Start();
				}

				if (!infoReady) {
					lock (statusLock) status.State = "Metadata";
					if (meta.Trackers.Count == 0 && !settings.EnableDht && string.IsNullOrEmpty(settings.ForcedPeer))
						Log(0, "magnet has no trackers, DHT is off, and no -Peer was given");
					Log(1, "fetching metadata");
					while (running && !infoReady) {
						if (VpnHub.Blocked) { Thread.Sleep(400); continue; }
						if (paused) { Thread.Sleep(250); continue; }
						RecyclePeers();
						FillPeers();
						Thread.Sleep(250);
					}
					if (!running) return;
					ApplyFetchedInfo();
				}

				lock (statusLock) status.State = "Preparing";
				pieces.Open();
				lock (statusLock) status.State = "Hashing";
				Log(1, "checking existing pieces...");
				pieces.HashCheck();
				if (!running) return;

				int dc0, tot0; long ver0, totb0;
				pieces.Snapshot(out dc0, out tot0, out ver0, out totb0);
				Log(1, "have " + dc0.ToString(CultureInfo.InvariantCulture) + "/" + tot0.ToString(CultureInfo.InvariantCulture) + " pieces (" + Fmt(ver0) + ")");

				if (meta.Trackers.Count > 0) {
					lock (statusLock) status.State = "Announcing";
					string ev = startedAnnounced ? "" : "started";
					AnnounceAll(ev);
					startedAnnounced = true;
				}

				if (meta.Webseeds.Count > 0) {
					int wn = Math.Min(4, Math.Max(2, meta.Webseeds.Count));
					if (Session.TorrentCount > 15) wn = 1;
					else if (Session.TorrentCount > 8) wn = Math.Min(wn, 2);
					for (int wi = 0; wi < wn; wi++) {
						Thread wt = new Thread(WebseedRun);
						wt.IsBackground = true;
						wt.Name = "pt-webseed";
						wt.Start();
					}
					Log(1, "webseeds: " + meta.Webseeds.Count.ToString(CultureInfo.InvariantCulture) + " (" + wn.ToString(CultureInfo.InvariantCulture) + " workers)");
				}

				DateTime lastAnn = DateTime.UtcNow;
				lastSp = DateTime.UtcNow;
				if (pieces != null) pieces.RefreshBudget();
				while (running) {
					if (VpnHub.Blocked) {
						ZeroRates();
						lock (statusLock) {
							status.State = "VPN";
							status.ErrorMessage = string.IsNullOrEmpty(VpnHub.LastError) ? "VPN down" : VpnHub.LastError;
						}
						Thread.Sleep(400);
						continue;
					}
					if (paused) {
						ZeroRates();
						lock (statusLock) status.State = "Paused";
						Thread.Sleep(250);
						continue;
					}
					UpdateSpeed();
					RecyclePeers();
					FillPeers();
					if (pieces.IsComplete) {
						if (settings.SeedAfterComplete) {
							lock (statusLock) {
								if (status.State != "Seeding") {
									status.State = "Seeding";
									Log(1, "download complete, seeding");
									ThreadPool.QueueUserWorkItem(delegate { try { AnnounceAll("completed"); } catch { } });
								}
							}
						} else {
							lock (statusLock) status.State = "Complete";
							Log(1, "download complete");
							ThreadPool.QueueUserWorkItem(delegate { try { AnnounceAll("completed"); } catch { } });
							running = false;
							break;
						}
					} else {
						lock (statusLock) {
							if (status.State != "Hashing") status.State = "Downloading";
						}
					}
					if ((DateTime.UtcNow - lastAnn).TotalSeconds >= announceInterval) {
						lastAnn = DateTime.UtcNow;
						ThreadPool.QueueUserWorkItem(delegate { try { AnnounceAll(""); } catch { } });
					}
					Thread.Sleep(50);
				}
			} catch (Exception ex) {
				lock (statusLock) {
					status.State = "Error";
					status.ErrorMessage = ex.Message;
				}
				Log(0, "engine error: " + ex.Message);
			}
		}

		void FillPeers() {
			if (paused) return;
			if (VpnHub.Blocked) return;
			int limit = Session.PeerLimit(this, settings.MaxPeers);
			int nT = Session.TorrentCount;
			int burst = nT > 20 ? 4 : (nT > 8 ? 8 : 24);
			for (int k = 0; k < burst; k++) {
				if (activePeerThreads >= limit) return;
				lock (peerLock) {
					if (activePeerThreads - peers.Count >= burst) return;
				}
				string ep = NextPeer();
				if (ep == null) return;
				string[] parts = ep.Split(':');
				if (parts.Length != 2) continue;
				int p;
				if (!int.TryParse(parts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out p)) continue;
				if (p <= 0 || p > 65535) continue;
				StartOutgoing(parts[0], p);
			}
		}

		void StartOutgoing(string host, int port) {
			if (!Session.TryBeginPeer()) return;
			Interlocked.Increment(ref activePeerThreads);
			Thread t = new Thread(delegate(object state) {
				try {
					object[] hp = (object[])state;
					PeerWorker w = new PeerWorker(this, (string)hp[0], (int)hp[1]);
					w.Run();
				} finally {
					Interlocked.Decrement(ref activePeerThreads);
					Session.EndPeer();
				}
			});
			t.IsBackground = true;
			t.Start(new object[] { host, port });
		}

		void StartListen() {
			int p = Session.EnsureListen(settings.ListenPort, settings.EnableUtp);
			if (p > 0) {
				boundPort = p;
				Log(1, "listening on TCP " + boundPort.ToString(CultureInfo.InvariantCulture)
					+ (Session.Utp != null ? " / UDP" : "")
					+ (VpnHub.TunnelOn ? " (VPN)" : ""));
				return;
			}
			boundPort = settings.ListenPort;
			if (VpnHub.Blocked) Log(1, "VPN down: not listening");
			else Log(1, "could not bind a listen port; outgoing connections only");
		}

		static void SendUdp(VpnUdpSock vs, UdpClient udp, byte[] req, IPEndPoint dest) {
			if (vs != null) vs.SendTo(req, dest);
			else udp.Send(req, req.Length);
		}
		static byte[] RecvUdp(VpnUdpSock vs, UdpClient udp, int timeoutMs) {
			if (vs != null) {
				byte[] d; IPEndPoint f;
				if (!vs.Recv(timeoutMs, out d, out f)) return null;
				return d;
			}
			IPEndPoint ep = new IPEndPoint(IPAddress.Any, 0);
			return udp.Receive(ref ep);
		}

		void AnnounceAll(string ev) {
			List<string> urls = meta.Trackers;
			if (urls.Count == 0) {
				Log(1, "no trackers in torrent");
				return;
			}
			List<string> collected = new List<string>();
			int remaining = urls.Count;
			ManualResetEvent done = new ManualResetEvent(false);
			for (int i = 0; i < urls.Count; i++) {
				ThreadPool.QueueUserWorkItem(delegate(object state) {
					string u = (string)state;
					try {
						List<string> local = new List<string>();
						string scheme = "";
						try { scheme = new Uri(u).Scheme.ToLowerInvariant(); } catch { }
						if (scheme == "udp") QueryUdp(u, ev, local);
						else if (scheme == "http" || scheme == "https") QueryHttp(u, ev, local);
						else Log(2, "skip tracker " + u);
						lock (collected) {
							for (int k = 0; k < local.Count; k++) collected.Add(local[k]);
						}
						if (local.Count > 0)
							Log(1, local.Count.ToString(CultureInfo.InvariantCulture) + " peers from " + u);
					} catch (Exception ex) {
						Log(2, "tracker " + u + " " + ex.Message);
					} finally {
						if (Interlocked.Decrement(ref remaining) == 0) done.Set();
					}
				}, urls[i]);
			}
			done.WaitOne(ev == "stopped" ? 2000 : 18000);
			lock (collected) {
				for (int i = 0; i < collected.Count; i++) RememberPeer(collected[i]);
			}
		}

		void QueryUdp(string url, string ev, List<string> peersOut) {
			Session.AcquireAnnounce();
			try { QueryUdpCore(url, ev, peersOut); }
			finally { Session.ReleaseAnnounce(); }
		}

		void QueryUdpCore(string url, string ev, List<string> peersOut) {
			if (VpnHub.HasConfig && !VpnHub.TunnelOn) { Log(2, "UDP blocked (VPN down)"); return; }
			Uri uri;
			try { uri = new Uri(url); } catch { return; }
			if (uri.Port <= 0) { Log(2, "UDP tracker missing port: " + url); return; }
			IPAddress ip = Bt.ResolveV4(uri.Host);
			if (ip == null) { Log(2, "UDP DNS failed: " + uri.Host); return; }
			VpnUdpSock vs = null;
			UdpClient udp = null;
			IPEndPoint dest = new IPEndPoint(ip, uri.Port);
			try {
				if (VpnHub.HasConfig) vs = VpnHub.BindUdp(0);
				else {
					udp = new UdpClient();
					udp.Client.ReceiveTimeout = 8000;
					udp.Connect(ip, uri.Port);
				}
				Random rng = new Random(Guid.NewGuid().GetHashCode());
				byte[] req = new byte[16];
				Bt.W64(req, 0, 0x41727101980L);
				Bt.W32(req, 8, 0);
				int tx = rng.Next();
				Bt.W32(req, 12, tx);
				SendUdp(vs, udp, req, dest);
				byte[] resp = RecvUdp(vs, udp, 8000);
				if (resp == null || resp.Length < 16) return;
				if (Bt.R32(resp, 0) != 0) return;
				if (Bt.R32(resp, 4) != tx) return;
				byte[] conn = new byte[8];
				Buffer.BlockCopy(resp, 8, conn, 0, 8);

				byte[] a = new byte[98];
				Buffer.BlockCopy(conn, 0, a, 0, 8);
				Bt.W32(a, 8, 1);
				tx = rng.Next();
				Bt.W32(a, 12, tx);
				Buffer.BlockCopy(infoHash, 0, a, 16, 20);
				Buffer.BlockCopy(peerId, 0, a, 36, 20);
				int dc = 0, totp = 0; long ver = 0, totb = 0;
				if (pieces != null) pieces.Snapshot(out dc, out totp, out ver, out totb);
				else totb = 1;
				Bt.W64(a, 56, Interlocked.Read(ref sessionDown));
				Bt.W64(a, 64, Math.Max(0, totb - ver));
				Bt.W64(a, 72, Interlocked.Read(ref sessionUp));
				int evn = 0;
				if (ev == "completed") evn = 1;
				else if (ev == "started") evn = 2;
				else if (ev == "stopped") evn = 3;
				Bt.W32(a, 80, evn);
				Bt.W32(a, 84, 0);
				Bt.W32(a, 88, rng.Next());
				Bt.W32(a, 92, 200);
				a[96] = (byte)((boundPort >> 8) & 0xFF);
				a[97] = (byte)(boundPort & 0xFF);
				SendUdp(vs, udp, a, dest);
				resp = RecvUdp(vs, udp, 8000);
				if (resp == null || resp.Length < 20) return;
				if (Bt.R32(resp, 4) != tx) return;
				int action = Bt.R32(resp, 0);
				if (action == 3) {
					Log(1, "UDP tracker error " + url);
					return;
				}
				if (action != 1) return;
				int iv = Bt.R32(resp, 8);
				if (iv >= 60) {
					lock (statusLock) {
						if (iv < announceInterval) announceInterval = iv;
					}
				}
				if (resp.Length >= 20) {
					int seeders = Bt.R32(resp, 16);
					if (seeders > 0) NoteSwarm(seeders);
				}
				if (resp.Length > 20) {
					byte[] compact = new byte[resp.Length - 20];
					Buffer.BlockCopy(resp, 20, compact, 0, compact.Length);
					Bt.AddCompactPeers(compact, peersOut);
				}
			} catch (Exception ex) {
				Log(2, "UDP " + url + " " + ex.Message);
			} finally {
				if (vs != null) VpnHub.DropUdp(vs);
				try { if (udp != null) udp.Close(); } catch { }
			}
		}

		void QueryHttp(string url, string ev, List<string> peersOut) {
			Session.AcquireAnnounce();
			try { QueryHttpCore(url, ev, peersOut); }
			finally { Session.ReleaseAnnounce(); }
		}

		void QueryHttpCore(string url, string ev, List<string> peersOut) {
			try {
				string sep = url.IndexOf('?') >= 0 ? "&" : "?";
				int dc = 0, totp = 0; long ver = 0, totb = 0;
				if (pieces != null) pieces.Snapshot(out dc, out totp, out ver, out totb);
				else totb = 1;
				StringBuilder sb = new StringBuilder();
				sb.Append(url);
				sb.Append(sep);
				sb.Append("info_hash=");
				sb.Append(Bt.UrlEnc(infoHash));
				sb.Append("&peer_id=");
				sb.Append(Bt.UrlEnc(peerId));
				sb.Append("&port=");
				sb.Append(boundPort.ToString(CultureInfo.InvariantCulture));
				sb.Append("&uploaded=");
				sb.Append(Interlocked.Read(ref sessionUp).ToString(CultureInfo.InvariantCulture));
				sb.Append("&downloaded=");
				sb.Append(Interlocked.Read(ref sessionDown).ToString(CultureInfo.InvariantCulture));
				sb.Append("&left=");
				sb.Append(Math.Max(0, totb - ver).ToString(CultureInfo.InvariantCulture));
				sb.Append("&compact=1&numwant=200&supportcrypto=1");
				if (!string.IsNullOrEmpty(ev)) {
					sb.Append("&event=");
					sb.Append(ev);
				}
				if (VpnHub.HasConfig && !VpnHub.TunnelOn) return;
				byte[] body;
				if (VpnHub.HasConfig) {
					int st;
					if (!VpnHub.HttpRequest(sb.ToString(), 15000, -1, -1, out st, out body) || body == null) return;
				} else {
					HttpWebRequest req = (HttpWebRequest)WebRequest.Create(sb.ToString());
					req.Method = "GET";
					req.UserAgent = "PowerTorrent/1.2";
					req.Timeout = 15000;
					req.ReadWriteTimeout = 15000;
					req.KeepAlive = false;
					req.AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate;
					using (HttpWebResponse resp = (HttpWebResponse)req.GetResponse())
					using (Stream rs = resp.GetResponseStream()) {
						MemoryStream ms = new MemoryStream();
						byte[] tmp = new byte[4096];
						int n;
						while ((n = rs.Read(tmp, 0, tmp.Length)) > 0) ms.Write(tmp, 0, n);
						body = ms.ToArray();
					}
				}
					Be dict = Benc.Decode(body);
					if (dict == null || dict.Dict == null) return;
					Be fail = dict.Get("failure reason");
					if (fail != null && fail.Bytes != null) {
						Log(1, "tracker " + url + ": " + Encoding.UTF8.GetString(fail.Bytes));
						return;
					}
					long iv = dict.GetInt("interval", 0);
					if (iv >= 60) {
						lock (statusLock) {
							if ((int)iv < announceInterval) announceInterval = (int)iv;
						}
					}
					int complete = (int)dict.GetInt("complete", -1);
					if (complete >= 0) NoteSwarm(complete);
					Be p = dict.Get("peers");
					if (p != null && p.Bytes != null) Bt.AddCompactPeers(p.Bytes, peersOut);
					else if (p != null && p.List != null) {
						for (int i = 0; i < p.List.Count; i++) {
							Be d2 = p.List[i];
							if (d2.Dict == null) continue;
							string ip = d2.Str("ip");
							long prt = d2.GetInt("port", 0);
							if (!string.IsNullOrEmpty(ip) && prt > 0)
								peersOut.Add(ip + ":" + prt.ToString(CultureInfo.InvariantCulture));
						}
					}
			} catch (Exception ex) {
				Log(2, "HTTP " + url + " " + ex.Message);
			}
		}

		static byte[] BuildGetPeers(byte[] nodeId, byte[] ih, byte[] tid) {
			MemoryStream ms = new MemoryStream();
			byte[] p1 = Encoding.ASCII.GetBytes("d1:ad2:id20:");
			ms.Write(p1, 0, p1.Length);
			ms.Write(nodeId, 0, 20);
			byte[] p2 = Encoding.ASCII.GetBytes("9:info_hash20:");
			ms.Write(p2, 0, p2.Length);
			ms.Write(ih, 0, 20);
			byte[] p3 = Encoding.ASCII.GetBytes("e1:q9:get_peers1:t");
			ms.Write(p3, 0, p3.Length);
			byte[] p4 = Encoding.ASCII.GetBytes(tid.Length.ToString(CultureInfo.InvariantCulture) + ":");
			ms.Write(p4, 0, p4.Length);
			ms.Write(tid, 0, tid.Length);
			byte[] p5 = Encoding.ASCII.GetBytes("1:y1:qe");
			ms.Write(p5, 0, p5.Length);
			return ms.ToArray();
		}

		static byte[] BuildAnnouncePeer(byte[] nodeId, byte[] ih, byte[] token, int port, byte[] tid) {
			MemoryStream ms = new MemoryStream();
			byte[] p1 = Encoding.ASCII.GetBytes("d1:ad2:id20:");
			ms.Write(p1, 0, p1.Length);
			ms.Write(nodeId, 0, 20);
			byte[] p2 = Encoding.ASCII.GetBytes("9:info_hash20:");
			ms.Write(p2, 0, p2.Length);
			ms.Write(ih, 0, 20);
			byte[] p3 = Encoding.ASCII.GetBytes("4:porti" + port.ToString(CultureInfo.InvariantCulture) + "e5:token" + token.Length.ToString(CultureInfo.InvariantCulture) + ":");
			ms.Write(p3, 0, p3.Length);
			ms.Write(token, 0, token.Length);
			byte[] p4 = Encoding.ASCII.GetBytes("e1:q13:announce_peer1:t" + tid.Length.ToString(CultureInfo.InvariantCulture) + ":");
			ms.Write(p4, 0, p4.Length);
			ms.Write(tid, 0, tid.Length);
			byte[] p5 = Encoding.ASCII.GetBytes("1:y1:qe");
			ms.Write(p5, 0, p5.Length);
			return ms.ToArray();
		}

		void DhtRun() {
			string[] boots = new string[] {
				"router.bittorrent.com:6881",
				"dht.transmissionbt.com:6881",
				"router.utorrent.com:6881",
				"dht.libtorrent.org:25401"
			};
			byte[] nid = new byte[20];
			RNGCryptoServiceProvider rng = new RNGCryptoServiceProvider();
			rng.GetBytes(nid);
			rng.Dispose();
			Queue<string> nodes = new Queue<string>();
			HashSet<string> tried = new HashSet<string>();
			for (int i = 0; i < boots.Length; i++) nodes.Enqueue(boots[i]);
			int queries = 0;
			int stagger = Session.IndexOf(this);
			if (stagger < 0) stagger = 0;
			Thread.Sleep(80 * (stagger % 25));
			while (running) {
				if (!settings.EnableDht) { Thread.Sleep(400); continue; }
				if (VpnHub.HasConfig && !VpnHub.TunnelOn) { Thread.Sleep(400); continue; }
				if (pieces != null && pieces.IsComplete) break;
				if (nodes.Count == 0) {
					tried.Clear();
					for (int i = 0; i < boots.Length; i++) nodes.Enqueue(boots[i]);
					Thread.Sleep(8000);
					continue;
				}
				string n = nodes.Dequeue();
				if (!tried.Add(n)) continue;
				queries++;
				if ((queries % 24) == 0) Thread.Sleep(1500);
				try {
					int colon = n.LastIndexOf(':');
					if (colon <= 0) continue;
					int p = int.Parse(n.Substring(colon + 1), CultureInfo.InvariantCulture);
					string h = n.Substring(0, colon);
					IPAddress ip = Bt.ResolveV4(h);
					if (ip == null) continue;
					byte[] tid = new byte[2];
					tid[0] = (byte)queries;
					tid[1] = 7;
					byte[] msg = BuildGetPeers(nid, infoHash, tid);
					VpnUdpSock vs = null;
					UdpClient udp = null;
					IPEndPoint dest = new IPEndPoint(ip, p);
					try {
						if (VpnHub.HasConfig) vs = VpnHub.BindUdp(0);
						else {
							udp = new UdpClient();
							udp.Client.ReceiveTimeout = 2500;
							udp.Connect(ip, p);
						}
						SendUdp(vs, udp, msg, dest);
						byte[] resp = RecvUdp(vs, udp, 2500);
						if (resp == null) continue;
						Be dict = Benc.Decode(resp);
						if (dict == null) continue;
						Be r = dict.Get("r");
						if (r == null) continue;
						Be values = r.Get("values");
						if (values != null && values.List != null) {
							int added = 0;
							for (int i = 0; i < values.List.Count; i++) {
								byte[] v = values.List[i].Bytes;
								if (v == null || v.Length < 6) continue;
								List<string> tmp = new List<string>();
								Bt.AddCompactPeers(v, tmp);
								for (int k = 0; k < tmp.Count; k++) {
									RememberPeer(tmp[k]);
									added++;
								}
							}
							if (added > 0) Log(1, "DHT +" + added.ToString(CultureInfo.InvariantCulture) + " peers from " + n);
						}
						Be tok = r.Get("token");
						if (tok != null && tok.Bytes != null && tok.Bytes.Length > 0 && tok.Bytes.Length <= 64 && boundPort > 0) {
							byte[] tid2 = new byte[2];
							tid2[0] = (byte)(queries + 3);
							tid2[1] = 9;
							byte[] amsg = BuildAnnouncePeer(nid, infoHash, tok.Bytes, boundPort, tid2);
							try { SendUdp(vs, udp, amsg, dest); } catch { }
						}
						Be nd = r.Get("nodes");
						if (nd != null && nd.Bytes != null) {
							byte[] nb = nd.Bytes;
							int cnt = nb.Length / 26;
							for (int i = 0; i < cnt; i++) {
								int o = i * 26 + 20;
								int np = (nb[o + 4] << 8) | nb[o + 5];
								if (np <= 0) continue;
								if (nb[o] == 0 || nb[o] == 127) continue;
								string ns = string.Format(CultureInfo.InvariantCulture, "{0}.{1}.{2}.{3}:{4}", nb[o], nb[o + 1], nb[o + 2], nb[o + 3], np);
								if (!tried.Contains(ns)) nodes.Enqueue(ns);
							}
						}
					} finally {
						if (vs != null) VpnHub.DropUdp(vs);
						try { if (udp != null) udp.Close(); } catch { }
					}
				} catch { }
			}
		}

		void WebseedRun() {
			while (running && pieces != null && !pieces.IsComplete) {
				if (paused) { Thread.Sleep(250); continue; }
				try {
					BitArray all = new BitArray(Math.Max(meta.PieceCount, 0));
					all.SetAll(true);
					int piece, begin, len;
					bool endgame = pieces.RemainingBlocks() <= 96;
					if (!pieces.TryClaim(all, settings.Sequential, endgame, out piece, out begin, out len)) {
						Thread.Sleep(1000);
						continue;
					}
					bool ok = false;
					for (int w = 0; w < meta.Webseeds.Count && !ok && running; w++) {
						ok = FetchWebseedBlock(meta.Webseeds[w], piece, begin, len);
					}
					if (!ok) {
						pieces.Unclaim(piece, begin);
						Thread.Sleep(800);
					}
				} catch {
					Thread.Sleep(1000);
				}
			}
		}

		bool FetchWebseedBlock(string baseUrl, int piece, int begin, int length) {
			long off = (long)piece * (long)meta.PieceLength + begin;
			byte[] data = new byte[length];
			long cursor = off;
			int remain = length;
			int bufOff = 0;
			for (int fi = 0; fi < meta.Files.Count && remain > 0; fi++) {
				FileEnt f = meta.Files[fi];
				long fe = f.Offset + f.Length;
				if (cursor >= fe || cursor < f.Offset) continue;
				long local = cursor - f.Offset;
				int n = (int)Math.Min((long)remain, f.Length - local);
				string url = CombineUrl(baseUrl, f.RelPath, meta.IsMulti);
				if (!HttpRange(url, local, n, data, bufOff)) return false;
				cursor += n;
				remain -= n;
				bufOff += n;
			}
			if (remain != 0) return false;
			int stored = pieces.Submit(piece, begin, data, 0, length);
			if (stored == 0) return false;
			if (stored == 2) BroadcastHave(piece);
			return true;
		}

		static string CombineUrl(string baseUrl, string rel, bool multi) {
			if (!multi) {
				if (baseUrl.EndsWith("/")) return baseUrl + rel.Replace('\\', '/');
				return baseUrl;
			}
			string r = rel.Replace('\\', '/');
			if (!baseUrl.EndsWith("/")) baseUrl += "/";
			return baseUrl + r;
		}

		bool HttpRange(string url, long start, int n, byte[] dest, int destOff) {
			if (VpnHub.HasConfig && !VpnHub.TunnelOn) return false;
			if (VpnHub.HasConfig) {
				int st; byte[] body;
				if (!VpnHub.HttpRequest(url, 20000, start, start + n - 1, out st, out body) || body == null) return false;
				if (st == 200 && start != 0) return false;
				if (st != 206 && st != 200) return false;
				if (body.Length < n) return false;
				Buffer.BlockCopy(body, 0, dest, destOff, n);
				return true;
			}
			HttpWebRequest req = (HttpWebRequest)WebRequest.Create(url);
			req.Method = "GET";
			req.UserAgent = "PowerTorrent/1.2";
			req.Timeout = 20000;
			req.ReadWriteTimeout = 20000;
			req.AddRange(start, start + n - 1);
			req.KeepAlive = false;
			using (HttpWebResponse resp = (HttpWebResponse)req.GetResponse()) {
				if (resp.StatusCode == HttpStatusCode.OK && start != 0) return false;
				if (resp.StatusCode != HttpStatusCode.PartialContent && resp.StatusCode != HttpStatusCode.OK) return false;
				using (Stream s = resp.GetResponseStream()) {
					int got = 0;
					while (got < n) {
						int r = s.Read(dest, destOff + got, n - got);
						if (r <= 0) return false;
						got += r;
					}
				}
				return true;
			}
		}
	}
}
'@

function Initialize-PowerTorrentEngine {
	if ('PowerTorrent.Engine' -as [type]) { return }
	Write-Host 'Starting PowerTorrent...' -ForegroundColor DarkCyan
	try {
		Add-Type -AssemblyName System.Numerics -ErrorAction SilentlyContinue | Out-Null
	} catch { }
	$refs = @()
	try { $refs += [Uri].Assembly.Location } catch { }
	try { $refs += [System.Numerics.BigInteger].Assembly.Location } catch { }
	try { $refs += [System.Linq.Enumerable].Assembly.Location } catch { }
	try {
		if ($refs.Count -gt 0) {
			Add-Type -TypeDefinition $script:PowerTorrentCSharp -Language CSharp -ReferencedAssemblies $refs -ErrorAction Stop
		} else {
			Add-Type -TypeDefinition $script:PowerTorrentCSharp -Language CSharp -ErrorAction Stop
		}
	} catch {
		Write-Host 'C# compile failed:' -ForegroundColor Red
		if ($_.Exception.InnerException -and $_.Exception.InnerException.LoaderExceptions) {
			$_.Exception.InnerException.LoaderExceptions | ForEach-Object { Write-Host $_.Message -ForegroundColor Red }
		}
		Write-Host $_ -ForegroundColor Red
		throw
	}
}

function Select-TorrentFile {
	if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
		throw 'File picker requires STA. Pass -Torrent <path> instead.'
	}
	Add-Type -AssemblyName System.Windows.Forms | Out-Null
	$dlg = New-Object System.Windows.Forms.OpenFileDialog
	$dlg.Filter = 'Torrent files (*.torrent)|*.torrent|All files (*.*)|*.*'
	$dlg.Title = 'Select a Torrent File'
	$dlg.InitialDirectory = (Get-Location).Path
	$dlg.Multiselect = $false
	if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
		return $dlg.FileName
	}
	return $null
}

function Write-Padded([string]$text, [ConsoleColor]$color = [ConsoleColor]::Gray) {
	$w = 80
	try { $w = [Math]::Max(40, [Console]::WindowWidth - 1) } catch { }
	if ($null -eq $text) { $text = '' }
	if ($text.Length -ge $w) { $text = $text.Substring(0, $w) }
	Write-Host ($text.PadRight($w)) -ForegroundColor $color
}

function Show-TorrentDashboard {
	param($s)
	$stateColor = switch ($s.State) {
		'Downloading' { [ConsoleColor]::Cyan }
		'Seeding'	  { [ConsoleColor]::Green }
		'Complete'	  { [ConsoleColor]::Green }
		'Error'		  { [ConsoleColor]::Red }
		'Hashing'	  { [ConsoleColor]::Yellow }
		'Announcing'  { [ConsoleColor]::Yellow }
		'Metadata'	  { [ConsoleColor]::Yellow }
		default		  { [ConsoleColor]::Gray }
	}
	Write-Padded '------------------------------------------------' ([ConsoleColor]::DarkGray)
	Write-Padded ("State	: {0}" -f $s.State) $stateColor
	Write-Padded ("Progress : {0,6:0.00}%	{1} / {2}" -f $s.ProgressPercent, [PowerTorrent.Engine]::Fmt([long]$s.Downloaded), [PowerTorrent.Engine]::Fmt([long]$s.TotalSize)) ([ConsoleColor]::White)
	Write-Padded ("Pieces	: {0} / {1}" -f $s.PiecesDone, $s.PiecesTotal)
	Write-Padded ("Peers	: {0} connected / {1} known	   seeds {2} / {3}   avail {4:0.0}" -f $s.PeersConnected, $s.PeersKnown, $s.SeedsConnected, $s.SeedsKnown, $s.Availability)
	Write-Padded ("Down		: {0}/s		Up : {1}/s	   ETA {2}" -f [PowerTorrent.Engine]::Fmt([long]$s.DownBytesPerSec), [PowerTorrent.Engine]::Fmt([long]$s.UpBytesPerSec), $s.Eta)
	$ratio = '--'
	if ($s.Downloaded -gt 0) { $ratio = ('{0:0.000}' -f ($s.Uploaded / [double]$s.Downloaded)) }
	elseif ($s.Uploaded -gt 0) { $ratio = [char]0x221E }
	Write-Padded ("Ratio	: {0}	  up {1}   down {2}" -f $ratio, [PowerTorrent.Engine]::Fmt([long]$s.Uploaded), [PowerTorrent.Engine]::Fmt([long]$s.Downloaded))
	if ($s.ErrorMessage) {
		Write-Padded ("Error	: {0}" -f $s.ErrorMessage) ([ConsoleColor]::Red)
	}
	Write-Padded ''
	Write-Padded 'Recent:' ([ConsoleColor]::DarkGray)
	$lines = @($s.LogLines)
	foreach ($line in $lines) {
		Write-Padded $line ([ConsoleColor]::DarkCyan)
	}
	for ($i = $lines.Count; $i -lt 8; $i++) { Write-Padded '' }
}

function Show-TorrentInfo {
	param($info)
	Write-Host ''
	Write-Host ("  Name		  : {0}" -f $info.Name) -ForegroundColor White
	Write-Host ("  Info hash  : {0}" -f $info.InfoHashHex) -ForegroundColor DarkGray
	Write-Host ("  Size		  : {0}	 ({1} piece(s) x {2})" -f [PowerTorrent.Engine]::Fmt([long]$info.TotalSize), $info.PieceCount, [PowerTorrent.Engine]::Fmt([long]$info.PieceLength))
	Write-Host ("  Files	  : {0}" -f $info.FileCount)
	if ($info.PieceCount -eq 0 -and $info.TotalSize -eq 0) {
		Write-Host '  (magnet: file list and size arrive after metadata is fetched)' -ForegroundColor Yellow
	}
	if ($info.Comment) { Write-Host ("	Comment	   : {0}" -f $info.Comment) }
	if ($info.CreatedBy) { Write-Host ("  Created by : {0}" -f $info.CreatedBy) }
	$trackers = @($info.Trackers)
	$webseeds = @($info.Webseeds)
	$files = @($info.Files)
	Write-Host ("  Trackers	  : {0}" -f $trackers.Count)
	$shown = [Math]::Min(8, $trackers.Count)
	for ($i = 0; $i -lt $shown; $i++) {
		Write-Host ("				{0}" -f $trackers[$i]) -ForegroundColor DarkGray
	}
	if ($trackers.Count -gt $shown) {
		Write-Host ("				... {0} more" -f ($trackers.Count - $shown)) -ForegroundColor DarkGray
	}
	if ($webseeds.Count -gt 0) {
		Write-Host ("  Webseeds	  : {0}" -f $webseeds.Count)
	}
	$fileShow = [Math]::Min(12, $files.Count)
	if ($fileShow -gt 0) {
		Write-Host '  Content	 :' -ForegroundColor DarkGray
		for ($i = 0; $i -lt $fileShow; $i++) {
			Write-Host ("				{0}" -f $files[$i]) -ForegroundColor DarkGray
		}
		if ($files.Count -gt $fileShow) {
			Write-Host ("				... {0} more files" -f ($files.Count - $fileShow)) -ForegroundColor DarkGray
		}
	}
	Write-Host ''
}

function Get-PowerTorrentScriptPath {
	$p = $PSCommandPath
	if ([string]::IsNullOrWhiteSpace($p)) { $p = $MyInvocation.MyCommand.Path }
	if ([string]::IsNullOrWhiteSpace($p)) { $p = Join-Path (Get-Location).Path 'PowerTorrent.ps1' }
	return [System.IO.Path]::GetFullPath($p)
}

function Get-PowerTorrentLaunchCommand {
	$exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
	$script = Get-PowerTorrentScriptPath
	return '"{0}" -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}" "%1"' -f $exe, $script
}

function Register-PowerTorrentAssociations {
	param([switch]$IncludeTorrentFiles)
	$cmd = Get-PowerTorrentLaunchCommand
	$hkcu = [Microsoft.Win32.Registry]::CurrentUser
	$magnet = $hkcu.CreateSubKey('Software\Classes\magnet')
	[void]$magnet.SetValue('', 'URL:BitTorrent Magnet')
	[void]$magnet.SetValue('URL Protocol', '')
	$icon = $magnet.CreateSubKey('DefaultIcon')
	[void]$icon.SetValue('', (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') + ',0')
	$open = $magnet.CreateSubKey('shell\open\command')
	[void]$open.SetValue('', $cmd)
	$magnet.Close()

	if ($IncludeTorrentFiles) {
		$prog = $hkcu.CreateSubKey('Software\Classes\PowerTorrent.torrent')
		[void]$prog.SetValue('', 'BitTorrent File')
		$popen = $prog.CreateSubKey('shell\open\command')
		[void]$popen.SetValue('', $cmd)
		$prog.Close()
		$ext = $hkcu.CreateSubKey('Software\Classes\.torrent')
		[void]$ext.SetValue('', 'PowerTorrent.torrent')
		$ext.Close()
	}
}

function Unregister-PowerTorrentAssociations {
	$hkcu = [Microsoft.Win32.Registry]::CurrentUser
	try { $hkcu.DeleteSubKeyTree('Software\Classes\magnet', $false) } catch { }
	try { $hkcu.DeleteSubKeyTree('Software\Classes\PowerTorrent.torrent', $false) } catch { }
	try {
		$ext = $hkcu.OpenSubKey('Software\Classes\.torrent', $true)
		if ($ext) {
			$cur = [string]$ext.GetValue('')
			if ($cur -eq 'PowerTorrent.torrent') {
				$hkcu.DeleteSubKeyTree('Software\Classes\.torrent', $false)
			}
			$ext.Close()
		}
	} catch { }
}

function Test-PowerTorrentMagnetAssociation {
	try {
		$k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Classes\magnet\shell\open\command')
		if (-not $k) { return $false }
		$v = [string]$k.GetValue('')
		$k.Close()
		$script = Get-PowerTorrentScriptPath
		return ($v -like ('*{0}*' -f [System.IO.Path]::GetFileName($script)))
	} catch { return $false }
}

function Get-DefaultSavePath {
	$dl = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads'
	if (Test-Path -LiteralPath $dl) { return $dl }
	return (Get-Location).Path
}

function Get-PtIniPath {
	$dir = Split-Path -Parent (Get-PowerTorrentScriptPath)
	Join-Path $dir 'PowerTorrent.ini'
}

function Get-PtLegacyIniPath {
	Join-Path $env:APPDATA 'PowerTorrent\PowerTorrent.ini'
}

function Get-PtDefaultOptions {
	[ordered]@{
		Theme		   = 'Ice'
		Dht			   = '1'
		Encrypt		   = '1'
		Utp			   = '1'
		Sequential	   = '0'
		Seed		   = '1'
		Port		   = '6881'
		MaxPeers	   = '80'
		SavePath	   = (Get-DefaultSavePath)
		CloseToTray	   = '0'
		NoticeAccepted = '0'
		VpnRequire	   = '1'
		VpnAuto		   = '1'
	}
}

function Read-PtIni {
	$map = @{}
	$p = Get-PtIniPath
	if (-not (Test-Path -LiteralPath $p)) {
		$legacy = Get-PtLegacyIniPath
		if (Test-Path -LiteralPath $legacy) { $p = $legacy }
		else { return $map }
	}
	try {
		foreach ($line in @(Get-Content -LiteralPath $p -Encoding UTF8 -ErrorAction Stop)) {
			$t = [string]$line
			if ($t.Trim().Length -eq 0) { continue }
			if ($t.StartsWith(';') -or $t.StartsWith('#') -or $t.StartsWith('[')) { continue }
			$eq = $t.IndexOf('=')
			if ($eq -lt 1) { continue }
			$k = $t.Substring(0, $eq).Trim()
			$v = $t.Substring($eq + 1).Trim()
			if ($k) { $map[$k] = $v }
		}
	} catch { }
	return $map
}

function Write-PtIni {
	param([hashtable]$Map)
	$p = Get-PtIniPath
	$dir = Split-Path -Parent $p
	if (-not (Test-Path -LiteralPath $dir)) {
		New-Item -ItemType Directory -Path $dir -Force | Out-Null
	}
	$keys = @('NoticeAccepted','Theme','Dht','Encrypt','Utp','Sequential','Seed','Port','MaxPeers','SavePath','CloseToTray','VpnRequire','VpnAuto')
	$lines = New-Object System.Collections.Generic.List[string]
	[void]$lines.Add('[PowerTorrent]')
	$seen = @{}
	foreach ($k in $keys) {
		if ($Map.ContainsKey($k)) {
			[void]$lines.Add(('{0}={1}' -f $k, [string]$Map[$k]))
			$seen[$k] = $true
		}
	}
	foreach ($k in @($Map.Keys)) {
		if (-not $seen.ContainsKey($k)) {
			[void]$lines.Add(('{0}={1}' -f $k, [string]$Map[$k]))
		}
	}
	Set-Content -LiteralPath $p -Value $lines.ToArray() -Encoding UTF8
}

function Merge-PtIni {
	param([hashtable]$Updates)
	$map = Read-PtIni
	foreach ($k in @($Updates.Keys)) { $map[$k] = [string]$Updates[$k] }
	Write-PtIni $map
}

function Test-PtIniFlag([string]$v) {
	if ([string]::IsNullOrWhiteSpace($v)) { return $false }
	switch ($v.Trim().ToLowerInvariant()) {
		'1' { return $true }
		'true' { return $true }
		'yes' { return $true }
		'on' { return $true }
		default { return $false }
	}
}

function Get-PtThemeNames {
	@('Ice','Ember','Forest','Violet','Steel','Light')
}

function Get-PtTheme {
	param([string]$Name)
	$n = [string]$Name
	if ([string]::IsNullOrWhiteSpace($n)) { $n = 'Ice' }
	switch ($n) {
		'Ember' {
			return @{
				WindowBg='#1C1410'; Text='#F8EDE4'; Muted='#C4B0A0'; Accent='#E09A5A'; AccentHi='#F0C090'; AccentDeep='#8A5A32'
				Hdr0='#2A1C14'; Hdr1='#18100C'; Tool0='#322218'; Tool1='#1C140E'; Bar0='#2A1E16'; Bar1='#18120E'
				Btn0='#5A3C28'; Btn1='#3A2418'; Hover0='#6A4A32'; Hover1='#4A3020'; Press0='#3A2418'; Press1='#24180E'
				Select0='#6A4028'; Select1='#4A2C1C'; Head0='#322218'; Head1='#1C140E'; Pop0='#322218'; Pop1='#1A120C'
				Fill='#2A1C14'; FillDeep='#140E0A'; Border='#8A5A32'; BorderHi='#F0C090'; ListBg='#201610'
				CaptionHover='#4A3020'; CaptionPress='#3A2418'; CloseHover='#C42B1C'; ClosePress='#9B2115'
				Ico='#F0C090'; CheckOn='#6A4028'; CheckMark='#F8EDE4'; Prog0='#F0C090'; Prog1='#C07838'; ProgHash0='#FFE066'; ProgHash1='#E0A800'
				Disabled='#7A6A5A'; RowEven='#1C1410'; RowOdd='#2E1E16'
			}
		}
		'Forest' {
			return @{
				WindowBg='#121A14'; Text='#E6F4EA'; Muted='#A8C4B0'; Accent='#5AA87A'; AccentHi='#8FD4A8'; AccentDeep='#2A5A3C'
				Hdr0='#14241A'; Hdr1='#0C1810'; Tool0='#1A2E22'; Tool1='#101C14'; Bar0='#16241A'; Bar1='#0E1812'
				Btn0='#2A4A38'; Btn1='#1A3024'; Hover0='#3A6A50'; Hover1='#2A4A38'; Press0='#1A3024'; Press1='#102018'
				Select0='#1E5A3C'; Select1='#164830'; Head0='#1A2E22'; Head1='#101C14'; Pop0='#1A2E22'; Pop1='#101A14'
				Fill='#14241A'; FillDeep='#0A140E'; Border='#3D6A50'; BorderHi='#8FD4A8'; ListBg='#101C14'
				CaptionHover='#2A4A38'; CaptionPress='#1A3024'; CloseHover='#C42B1C'; ClosePress='#9B2115'
				Ico='#8FD4A8'; CheckOn='#1E5A3C'; CheckMark='#E6F4EA'; Prog0='#8FD4A8'; Prog1='#2EA043'; ProgHash0='#FFE066'; ProgHash1='#E0A800'
				Disabled='#6A7A70'; RowEven='#121A14'; RowOdd='#1A2C20'
			}
		}
		'Violet' {
			return @{
				WindowBg='#16141C'; Text='#F0E8F8'; Muted='#B8A8C8'; Accent='#A78BDA'; AccentHi='#C4B0F0'; AccentDeep='#5A3A88'
				Hdr0='#201828'; Hdr1='#140E1C'; Tool0='#2A2038'; Tool1='#181422'; Bar0='#221A2C'; Bar1='#16101E'
				Btn0='#3A2A50'; Btn1='#241832'; Hover0='#4A3A68'; Hover1='#342448'; Press0='#241832'; Press1='#181022'
				Select0='#4A2A68'; Select1='#3A1E50'; Head0='#2A2038'; Head1='#181422'; Pop0='#2A2038'; Pop1='#16101E'
				Fill='#201828'; FillDeep='#0E0A14'; Border='#6A4A98'; BorderHi='#C4B0F0'; ListBg='#14101C'
				CaptionHover='#342448'; CaptionPress='#241832'; CloseHover='#C42B1C'; ClosePress='#9B2115'
				Ico='#C4B0F0'; CheckOn='#4A2A68'; CheckMark='#F0E8F8'; Prog0='#C4B0F0'; Prog1='#7A5AB8'; ProgHash0='#FFE066'; ProgHash1='#E0A800'
				Disabled='#6A6078'; RowEven='#16141C'; RowOdd='#221A2C'
			}
		}
		'Steel' {
			return @{
				WindowBg='#1A1C1E'; Text='#E8EAEC'; Muted='#A8B0B4'; Accent='#7A8A98'; AccentHi='#B0B8C0'; AccentDeep='#3A4A58'
				Hdr0='#22262A'; Hdr1='#141618'; Tool0='#2A2E32'; Tool1='#1A1C1E'; Bar0='#24282C'; Bar1='#16181A'
				Btn0='#3A4248'; Btn1='#24282C'; Hover0='#4A545C'; Hover1='#343A40'; Press0='#24282C'; Press1='#181A1C'
				Select0='#3A4A58'; Select1='#2A3844'; Head0='#2A2E32'; Head1='#1A1C1E'; Pop0='#2A2E32'; Pop1='#181A1C'
				Fill='#22262A'; FillDeep='#101214'; Border='#5A646C'; BorderHi='#B0B8C0'; ListBg='#181A1C'
				CaptionHover='#343A40'; CaptionPress='#24282C'; CloseHover='#C42B1C'; ClosePress='#9B2115'
				Ico='#B0B8C0'; CheckOn='#3A4A58'; CheckMark='#F4F6F8'; Prog0='#8FA0B0'; Prog1='#4A6A80'; ProgHash0='#FFE066'; ProgHash1='#E0A800'
				Disabled='#6A7078'; RowEven='#1A1C1E'; RowOdd='#262A2E'
			}
		}
		'Light' {
			return @{
				WindowBg='#F2F4F6'; Text='#0B1014'; Muted='#1C2A32'; Accent='#18616F'; AccentHi='#0E4852'; AccentDeep='#3E7A88'
				Hdr0='#FCFDFE'; Hdr1='#E4EAEE'; Tool0='#F4F6F8'; Tool1='#E2E8EC'; Bar0='#F2F4F6'; Bar1='#DCE3E8'
				Btn0='#E6ECF0'; Btn1='#CDD6DC'; Hover0='#D2DEE4'; Hover1='#B7C9D2'; Press0='#B7C9D2'; Press1='#9CB4BE'
				Select0='#C3D8E0'; Select1='#A7C8D2'; Head0='#ECF0F3'; Head1='#DCE3E8'; Pop0='#FCFDFE'; Pop1='#E8EEF2'
				Fill='#FFFFFF'; FillDeep='#DCE3E8'; Border='#5A727C'; BorderHi='#18616F'; ListBg='#E4EAEE'
				CaptionHover='#D5DEE4'; CaptionPress='#B7C6CE'; CloseHover='#C42B1C'; ClosePress='#9B2115'
				Ico='#102830'; CheckOn='#18616F'; CheckMark='#FFFFFF'; Prog0='#178A42'; Prog1='#116C34'; ProgHash0='#B88600'; ProgHash1='#946C00'
				Disabled='#4A5C64'; RowEven='#FFFFFF'; RowOdd='#E2E8EC'
			}
		}
		default {
			return @{
				WindowBg='#141A1E'; Text='#E8F4F8'; Muted='#A8C4CC'; Accent='#6BB3C4'; AccentHi='#8FD4E3'; AccentDeep='#1E4A5C'
				Hdr0='#1A242C'; Hdr1='#10161A'; Tool0='#243038'; Tool1='#172026'; Bar0='#1E2A32'; Bar1='#141C22'
				Btn0='#334650'; Btn1='#1E2C34'; Hover0='#3E5C68'; Hover1='#2A4450'; Press0='#1A3A48'; Press1='#122830'
				Select0='#245A6C'; Select1='#1A3E4C'; Head0='#243038'; Head1='#182228'; Pop0='#243038'; Pop1='#161E24'
				Fill='#1A2228'; FillDeep='#10161A'; Border='#3D5A66'; BorderHi='#8FD4E3'; ListBg='#151C22'
				CaptionHover='#2A4450'; CaptionPress='#1A3A48'; CloseHover='#C42B1C'; ClosePress='#9B2115'
				Ico='#C5E8F0'; CheckOn='#1E4A5C'; CheckMark='#E8F4F8'; Prog0='#6EE08A'; Prog1='#2EA043'; ProgHash0='#FFE066'; ProgHash1='#E0A800'
				Disabled='#6A7A80'; RowEven='#141A1E'; RowOdd='#1E2A32'
			}
		}
	}
}

function Initialize-PowerTorrentThemeUtil {
	if ('PowerTorrent.ThemeUtil' -as [type]) { return }
	Add-Type -AssemblyName PresentationCore | Out-Null
	Add-Type -AssemblyName PresentationFramework | Out-Null
	Add-Type -AssemblyName WindowsBase | Out-Null
	$cs = @'
using System.Windows;
using System.Windows.Media;
using System.Windows.Shapes;

namespace PowerTorrent {
	public static class ThemeUtil {
		public static void PutSolid(ResourceDictionary rd, string key, byte r, byte g, byte b) {
			PutSolidObj(rd, key, r, g, b);
		}

		public static void PutSys(ResourceDictionary rd, ResourceKey key, byte r, byte g, byte b) {
			PutSolidObj(rd, key, r, g, b);
		}

		static void PutSolidObj(ResourceDictionary rd, object key, byte r, byte g, byte b) {
			if (rd == null || key == null) return;
			Color c = Color.FromRgb(r, g, b);
			object existing = null;
			if (rd.Contains(key)) existing = rd[key];
			SolidColorBrush sb = existing as SolidColorBrush;
			if (sb != null && !sb.IsFrozen) {
				sb.Color = c;
				return;
			}
			SolidColorBrush brush = new SolidColorBrush(c);
			if (rd.Contains(key)) rd.Remove(key);
			rd.Add(key, brush);
		}

		public static void PutGrad(ResourceDictionary rd, string key, byte r1, byte g1, byte b1, byte r2, byte g2, byte b2, bool horizontal) {
			if (rd == null || key == null) return;
			object existing = null;
			if (rd.Contains(key)) existing = rd[key];
			LinearGradientBrush old = existing as LinearGradientBrush;
			if (old != null && !old.IsFrozen && old.GradientStops != null && old.GradientStops.Count >= 2) {
				old.GradientStops[0].Color = Color.FromRgb(r1, g1, b1);
				old.GradientStops[1].Color = Color.FromRgb(r2, g2, b2);
				return;
			}
			LinearGradientBrush brush = new LinearGradientBrush();
			brush.StartPoint = new Point(0, 0);
			brush.EndPoint = horizontal ? new Point(1, 0) : new Point(0, 1);
			brush.GradientStops.Add(new GradientStop(Color.FromRgb(r1, g1, b1), 0));
			brush.GradientStops.Add(new GradientStop(Color.FromRgb(r2, g2, b2), 1));
			if (rd.Contains(key)) rd.Remove(key);
			rd.Add(key, brush);
		}

		public static void SetPathStrokeRgb(Path path, byte r, byte g, byte b) {
			if (path == null) return;
			path.Stroke = new SolidColorBrush(Color.FromRgb(r, g, b));
		}

		public static void SetPathStrokeKey(Path path, ResourceDictionary rd, string key) {
			if (path == null || rd == null || key == null) return;
			Brush b = rd[key] as Brush;
			if (b != null) path.Stroke = b;
		}
	}
}
'@
	$refs = @(
		[System.Windows.Media.SolidColorBrush].Assembly.Location,
		[System.Windows.Window].Assembly.Location,
		[System.Windows.Point].Assembly.Location,
		[System.Windows.Shapes.Path].Assembly.Location,
		([System.Reflection.Assembly]::Load('System.Xaml, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089')).Location
	) | Select-Object -Unique
	Add-Type -TypeDefinition $cs -ReferencedAssemblies $refs -ErrorAction Stop
}

function Convert-PtColor([string]$Hex) {
	$h = ([string]$Hex).Trim().TrimStart('#')
	if ($h.Length -eq 8) { $h = $h.Substring(2) }
	if ($h.Length -ne 6) { return [System.Windows.Media.Colors]::Black }
	$rv = [Convert]::ToByte($h.Substring(0, 2), 16)
	$gv = [Convert]::ToByte($h.Substring(2, 2), 16)
	$bv = [Convert]::ToByte($h.Substring(4, 2), 16)
	return [System.Windows.Media.Color]::FromRgb($rv, $gv, $bv)
}

function Set-PtSolid {
	param($Window, $Key, [string]$Hex)
	if (-not $Window) { return }
	if (-not ('PowerTorrent.ThemeUtil' -as [type])) { Initialize-PowerTorrentThemeUtil }
	$c = Convert-PtColor $Hex
	$rd = $Window.Resources
	if ($Key -is [System.Windows.ResourceKey]) {
		[PowerTorrent.ThemeUtil]::PutSys($rd, $Key, $c.R, $c.G, $c.B)
	} else {
		[PowerTorrent.ThemeUtil]::PutSolid($rd, [string]$Key, $c.R, $c.G, $c.B)
	}
}

function Set-PtGrad {
	param($Window, [string]$Key, [string]$A, [string]$B)
	if (-not $Window) { return }
	if (-not ('PowerTorrent.ThemeUtil' -as [type])) { Initialize-PowerTorrentThemeUtil }
	$ca = Convert-PtColor $A
	$cb = Convert-PtColor $B
	$horiz = ($Key -eq 'SelectFace' -or $Key -eq 'HoverFace')
	[PowerTorrent.ThemeUtil]::PutGrad($Window.Resources, $Key, $ca.R, $ca.G, $ca.B, $cb.R, $cb.G, $cb.B, $horiz)
}

function Apply-PtTheme {
	param($Window, [string]$Name)
	if (-not $Window) { return }
	if (-not ('PowerTorrent.ThemeUtil' -as [type])) { Initialize-PowerTorrentThemeUtil }
	$t = Get-PtTheme $Name
	Set-PtSolid $Window 'Theme.WindowBg' $t.WindowBg
	Set-PtSolid $Window 'Theme.Text' $t.Text
	Set-PtSolid $Window 'Theme.Muted' $t.Muted
	Set-PtSolid $Window 'Theme.Accent' $t.Accent
	Set-PtSolid $Window 'Theme.AccentHi' $t.AccentHi
	Set-PtSolid $Window 'Theme.AccentDeep' $t.AccentDeep
	Set-PtSolid $Window 'Theme.Fill' $t.Fill
	Set-PtSolid $Window 'Theme.FillDeep' $t.FillDeep
	Set-PtSolid $Window 'Theme.Border' $t.Border
	Set-PtSolid $Window 'Theme.BorderHi' $t.BorderHi
	Set-PtSolid $Window 'Theme.ListBg' $t.ListBg
	Set-PtSolid $Window 'Theme.CaptionHover' $t.CaptionHover
	Set-PtSolid $Window 'Theme.CaptionPress' $t.CaptionPress
	Set-PtSolid $Window 'Theme.CloseHover' $t.CloseHover
	Set-PtSolid $Window 'Theme.ClosePress' $t.ClosePress
	Set-PtSolid $Window 'Theme.Ico' $t.Ico
	Set-PtSolid $Window 'Theme.CheckOn' $t.CheckOn
	Set-PtSolid $Window 'Theme.CheckMark' $t.CheckMark
	Set-PtSolid $Window 'Theme.Disabled' $t.Disabled
	Set-PtSolid $Window 'Theme.RowEven' $t.RowEven
	Set-PtSolid $Window 'Theme.RowOdd' $t.RowOdd
	Set-PtGrad $Window 'HdrFace' $t.Hdr0 $t.Hdr1
	Set-PtGrad $Window 'ToolFace' $t.Tool0 $t.Tool1
	Set-PtGrad $Window 'BarFace' $t.Bar0 $t.Bar1
	Set-PtGrad $Window 'BtnFace' $t.Btn0 $t.Btn1
	Set-PtGrad $Window 'BtnHover' $t.Hover0 $t.Hover1
	Set-PtGrad $Window 'BtnPress' $t.Press0 $t.Press1
	Set-PtGrad $Window 'SelectFace' $t.Select0 $t.Select1
	Set-PtGrad $Window 'HoverFace' $t.Hover0 $t.Hover1
	Set-PtGrad $Window 'HeadFace' $t.Head0 $t.Head1
	Set-PtGrad $Window 'PopFace' $t.Pop0 $t.Pop1
	Set-PtGrad $Window 'ProgGreen' $t.Prog0 $t.Prog1
	Set-PtGrad $Window 'ProgYellow' $t.ProgHash0 $t.ProgHash1
	try {
		Set-PtSolid $Window ([System.Windows.SystemColors]::HighlightBrushKey) $t.AccentDeep
		Set-PtSolid $Window ([System.Windows.SystemColors]::HighlightTextBrushKey) $t.Text
		Set-PtSolid $Window ([System.Windows.SystemColors]::InactiveSelectionHighlightBrushKey) $t.Fill
		Set-PtSolid $Window ([System.Windows.SystemColors]::InactiveSelectionHighlightTextBrushKey) $t.Muted
		Set-PtSolid $Window ([System.Windows.SystemColors]::WindowBrushKey) $t.WindowBg
		Set-PtSolid $Window ([System.Windows.SystemColors]::WindowTextBrushKey) $t.Text
	} catch { }
}

function Show-PtNoticeGui {
	Add-Type -AssemblyName PresentationFramework | Out-Null
	$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
		xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
		Title="PowerTorrent" SizeToContent="WidthAndHeight"
		WindowStartupLocation="CenterScreen" WindowStyle="None"
		ResizeMode="NoResize" Background="{DynamicResource Theme.WindowBg}"
		Foreground="{DynamicResource Theme.Text}"
		FontFamily="Segoe UI" FontSize="13"
		BorderBrush="{DynamicResource Theme.Accent}" BorderThickness="1">
  <Window.Resources>
	<SolidColorBrush x:Key="Theme.WindowBg" Color="#141A1E"/>
	<SolidColorBrush x:Key="Theme.Text" Color="#E8F4F8"/>
	<SolidColorBrush x:Key="Theme.Muted" Color="#A8C4CC"/>
	<SolidColorBrush x:Key="Theme.Accent" Color="#6BB3C4"/>
	<SolidColorBrush x:Key="Theme.AccentHi" Color="#8FD4E3"/>
	<SolidColorBrush x:Key="Theme.AccentDeep" Color="#1E4A5C"/>
	<SolidColorBrush x:Key="Theme.Fill" Color="#1A2228"/>
	<SolidColorBrush x:Key="Theme.FillDeep" Color="#10161A"/>
	<SolidColorBrush x:Key="Theme.Border" Color="#3D5A66"/>
	<SolidColorBrush x:Key="Theme.BorderHi" Color="#8FD4E3"/>
	<SolidColorBrush x:Key="Theme.ListBg" Color="#151C22"/>
	<SolidColorBrush x:Key="Theme.CaptionHover" Color="#2A4450"/>
	<SolidColorBrush x:Key="Theme.CaptionPress" Color="#1A3A48"/>
	<SolidColorBrush x:Key="Theme.CloseHover" Color="#C42B1C"/>
	<SolidColorBrush x:Key="Theme.ClosePress" Color="#9B2115"/>
	<SolidColorBrush x:Key="Theme.Ico" Color="#C5E8F0"/>
	<SolidColorBrush x:Key="Theme.CheckOn" Color="#1E4A5C"/>
	<SolidColorBrush x:Key="Theme.CheckMark" Color="#E8F4F8"/>
	<SolidColorBrush x:Key="Theme.Disabled" Color="#6A7A80"/>
	<LinearGradientBrush x:Key="BtnFace" StartPoint="0,0" EndPoint="0,1">
	  <GradientStop Color="#334650" Offset="0"/>
	  <GradientStop Color="#1E2C34" Offset="1"/>
	</LinearGradientBrush>
	<LinearGradientBrush x:Key="BtnHover" StartPoint="0,0" EndPoint="0,1">
	  <GradientStop Color="#3E5C68" Offset="0"/>
	  <GradientStop Color="#2A4450" Offset="1"/>
	</LinearGradientBrush>
	<LinearGradientBrush x:Key="BtnPress" StartPoint="0,0" EndPoint="0,1">
	  <GradientStop Color="#1A3A48" Offset="0"/>
	  <GradientStop Color="#122830" Offset="1"/>
	</LinearGradientBrush>
	<StreamGeometry x:Key="GeoCheck">M21,7L9,19L3.5,13.5L4.91,12.09L9,16.17L19.59,5.59L21,7Z</StreamGeometry>
	<Style TargetType="TextBlock">
	  <Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
	</Style>
	<Style TargetType="Button">
	  <Setter Property="Background" Value="{DynamicResource BtnFace}"/>
	  <Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
	  <Setter Property="BorderBrush" Value="{DynamicResource Theme.Border}"/>
	  <Setter Property="BorderThickness" Value="1"/>
	  <Setter Property="Padding" Value="10,4"/>
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="Button">
			<Border x:Name="bd" Background="{TemplateBinding Background}"
					BorderBrush="{TemplateBinding BorderBrush}"
					BorderThickness="{TemplateBinding BorderThickness}"
					Padding="{TemplateBinding Padding}" CornerRadius="3">
			  <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
			</Border>
			<ControlTemplate.Triggers>
			  <Trigger Property="IsMouseOver" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource BtnHover}"/>
				<Setter TargetName="bd" Property="BorderBrush" Value="{DynamicResource Theme.AccentHi}"/>
			  </Trigger>
			  <Trigger Property="IsPressed" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource BtnPress}"/>
			  </Trigger>
			</ControlTemplate.Triggers>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style TargetType="CheckBox">
	  <Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="CheckBox">
			<StackPanel Orientation="Horizontal">
			  <Border x:Name="box" Width="16" Height="16" Background="{DynamicResource Theme.Fill}"
					  BorderBrush="{DynamicResource Theme.Border}" BorderThickness="1" CornerRadius="2"
					  Margin="0,0,8,0" VerticalAlignment="Center">
				<Path x:Name="check" Data="{StaticResource GeoCheck}" Fill="{DynamicResource Theme.CheckMark}"
					  Stretch="Uniform" Margin="2" Visibility="Collapsed"/>
			  </Border>
			  <ContentPresenter VerticalAlignment="Center" RecognizesAccessKey="True"/>
			</StackPanel>
			<ControlTemplate.Triggers>
			  <Trigger Property="IsChecked" Value="True">
				<Setter TargetName="check" Property="Visibility" Value="Visible"/>
				<Setter TargetName="box" Property="Background" Value="{DynamicResource Theme.CheckOn}"/>
				<Setter TargetName="box" Property="BorderBrush" Value="{DynamicResource Theme.Accent}"/>
			  </Trigger>
			  <Trigger Property="IsMouseOver" Value="True">
				<Setter TargetName="box" Property="BorderBrush" Value="{DynamicResource Theme.AccentHi}"/>
			  </Trigger>
			</ControlTemplate.Triggers>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
  </Window.Resources>
  <Border Padding="22,18" Background="{DynamicResource Theme.WindowBg}">
	<StackPanel Width="380">
	  <TextBlock Text="PowerTorrent" FontWeight="SemiBold" FontSize="15" Margin="0,0,0,10"
				 Foreground="{DynamicResource Theme.Text}"/>
	  <TextBlock TextWrapping="Wrap" Margin="0,0,0,16" Foreground="{DynamicResource Theme.Text}"
				 Text="Please follow copyright and local laws when using this BitTorrent client."/>
	  <CheckBox x:Name="chkRemember" Content="Remember this" Margin="0,0,0,16"/>
	  <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
		<Button x:Name="btnOk" Content="OK" Width="84" Height="28" Margin="0,0,8,0" IsDefault="True"/>
		<Button x:Name="btnCancel" Content="Cancel" Width="84" Height="28" IsCancel="True"/>
	  </StackPanel>
	</StackPanel>
  </Border>
</Window>
'@
	$w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$xaml)))
	$chk = $w.FindName('chkRemember')
	$ok = $w.FindName('btnOk')
	$cancel = $w.FindName('btnCancel')
	$script:PtNoticeOk = $false
	$script:PtNoticeRemember = $false
	try {
		$th = $script:PtTheme
		if ([string]::IsNullOrWhiteSpace($th)) { $th = 'Ice' }
		Apply-PtTheme $w $th
	} catch { }
	$ok.add_Click({
		$script:PtNoticeOk = $true
		$script:PtNoticeRemember = ($chk.IsChecked -eq $true)
		try { $w.DialogResult = $true } catch { }
	})
	$cancel.add_Click({
		try { $w.DialogResult = $false } catch { }
	})
	[void]$w.ShowDialog()
	return @{ Ok = [bool]$script:PtNoticeOk; Remember = [bool]$script:PtNoticeRemember }
}

function Show-PtNoticeCli {
	Write-Host ''
	Write-Host 'Please follow copyright and local laws when using this BitTorrent client.'
	Write-Host ''
	Write-Host '  Enter / Y	 continue once'
	Write-Host '  R			 remember this (writes a small settings file)'
	Write-Host '  N / Q		 cancel'
	Write-Host ''
	$ans = Read-Host 'Choice'
	$a = $ans.Trim().ToLowerInvariant()
	switch ($a) {
		'' { return @{ Ok = $true; Remember = $false } }
		'y' { return @{ Ok = $true; Remember = $false } }
		'yes' { return @{ Ok = $true; Remember = $false } }
		'r' { return @{ Ok = $true; Remember = $true } }
		'remember' { return @{ Ok = $true; Remember = $true } }
		default { return @{ Ok = $false; Remember = $false } }
	}
}

function Confirm-PowerTorrentNotice {
	param([switch]$Gui)
	$ini = Read-PtIni
	if (Test-PtIniFlag $ini['NoticeAccepted']) { return $true }
	if ($RememberAccept) {
		Merge-PtIni @{ NoticeAccepted = '1' }
		return $true
	}
	if ($Accept) { return $true }
	$r = $null
	if ($Gui) { $r = Show-PtNoticeGui } else { $r = Show-PtNoticeCli }
	if (-not $r.Ok) { return $false }
	if ($r.Remember) { Merge-PtIni @{ NoticeAccepted = '1' } }
	return $true
}

function Import-PtIniToSession {
	$ini = Read-PtIni
	if ($ini.Count -eq 0) { return }
	if (-not $PSBoundParameters.ContainsKey('Port') -and $ini.ContainsKey('Port')) {
		$v = 0
		if ([int]::TryParse($ini['Port'], [ref]$v) -and $v -gt 0) { $script:Port = $v }
	}
	if (-not $PSBoundParameters.ContainsKey('MaxPeers') -and $ini.ContainsKey('MaxPeers')) {
		$v = 0
		if ([int]::TryParse($ini['MaxPeers'], [ref]$v) -and $v -gt 0) { $script:MaxPeers = $v }
	}
	if (-not $PSBoundParameters.ContainsKey('SavePath') -and $ini.ContainsKey('SavePath') -and $ini['SavePath']) {
		$script:SavePath = $ini['SavePath']
	}
	if (-not $PSBoundParameters.ContainsKey('Sequential') -and $ini.ContainsKey('Sequential')) {
		$script:Sequential = [switch](Test-PtIniFlag $ini['Sequential'])
	}
	if (-not $PSBoundParameters.ContainsKey('NoDht') -and $ini.ContainsKey('Dht')) {
		$script:NoDht = [switch](-not (Test-PtIniFlag $ini['Dht']))
	}
	if (-not $PSBoundParameters.ContainsKey('NoEncrypt') -and $ini.ContainsKey('Encrypt')) {
		$script:NoEncrypt = [switch](-not (Test-PtIniFlag $ini['Encrypt']))
	}
	if (-not $PSBoundParameters.ContainsKey('NoUtp') -and $ini.ContainsKey('Utp')) {
		$script:NoUtp = [switch](-not (Test-PtIniFlag $ini['Utp']))
	}
	if (-not $PSBoundParameters.ContainsKey('NoSeed') -and $ini.ContainsKey('Seed')) {
		$script:NoSeed = [switch](-not (Test-PtIniFlag $ini['Seed']))
	}
	if ($ini.ContainsKey('Theme') -and $ini['Theme']) { $script:PtTheme = $ini['Theme'] }
	if ($ini.ContainsKey('CloseToTray')) { $script:PtCloseToTray = Test-PtIniFlag $ini['CloseToTray'] }
	if ($ini.ContainsKey('VpnRequire')) { $script:PtVpnRequire = Test-PtIniFlag $ini['VpnRequire'] }
	if ($ini.ContainsKey('VpnAuto')) { $script:PtVpnAuto = Test-PtIniFlag $ini['VpnAuto'] }
}

function Get-PtVpnConfPath {
	Join-Path (Split-Path -Parent (Get-PowerTorrentScriptPath)) 'PowerTorrent.vpn.conf'
}

function Initialize-PtVpn {
	if ($null -eq $script:PtVpnRequire) { $script:PtVpnRequire = $true }
	if ($null -eq $script:PtVpnAuto) { $script:PtVpnAuto = $true }
	$conf = Get-PtVpnConfPath
	if (-not (Test-Path -LiteralPath $conf)) { return }
	try {
		$text = [System.IO.File]::ReadAllText($conf)
		$err = ''
		$ok = [PowerTorrent.VpnHub]::LoadConfig($text, [ref]$err)
		if (-not $ok) {
			Write-Host ("VPN config: {0}" -f $err) -ForegroundColor Yellow
			return
		}
		[PowerTorrent.VpnHub]::Require = [bool]$script:PtVpnRequire
		if ([bool]$script:PtVpnAuto) {
			Write-Host 'Connecting VPN...' -ForegroundColor DarkCyan
			$up = [PowerTorrent.VpnHub]::Start()
			if ($up) {
				Write-Host ("VPN {0}" -f [PowerTorrent.VpnHub]::Status) -ForegroundColor Green
			} else {
				Write-Host ("VPN failed: {0}" -f [PowerTorrent.VpnHub]::LastError) -ForegroundColor Yellow
			}
		}
	} catch {
		Write-Host ("VPN: {0}" -f $_) -ForegroundColor Yellow
	}
}

function Get-PtBoolText([bool]$v) {
	if ($v) { '1' } else { '0' }
}

function Get-PtInt {
	param(
		[string]$Text,
		[int]$Fallback
	)
	$n = 0
	$s = [string]$Text
	if ([int]::TryParse($s, [ref]$n) -and $n -gt 0) { return $n }
	return $Fallback
}

function Get-PtInboxPath {
	Join-Path $env:TEMP 'PowerTorrent.inbox'
}

function Send-PtInbox([string]$source) {
	if ([string]::IsNullOrWhiteSpace($source)) { return }
	Add-Content -LiteralPath (Get-PtInboxPath) -Value $source.Trim() -Encoding UTF8
}

function Read-PtInbox {
	$p = Get-PtInboxPath
	if (-not (Test-Path -LiteralPath $p)) { return @() }
	try {
		$lines = @(Get-Content -LiteralPath $p -ErrorAction Stop)
		Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
		return @($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
	} catch { return @() }
}

function New-PowerTorrentSettings {
	param(
		[string]$Source,
		[string]$OutDir,
		[int]$ListenPort = 6881,
		[int]$Peers = 80,
		[bool]$Dht = $true,
		[bool]$Encrypt = $true,
		[bool]$Utp = $true,
		[bool]$Seq = $false,
		[bool]$Seed = $true,
		[string]$Forced = '',
		[int]$Level = 1
	)
	if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Get-DefaultSavePath }
	$OutDir = [System.IO.Path]::GetFullPath($OutDir)
	if (-not (Test-Path -LiteralPath $OutDir)) {
		New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
	}
	$cfg = [PowerTorrent.EngineSettings]::new()
	$src = $Source.Trim()
	if ($src.ToLowerInvariant().StartsWith('magnet:')) {
		$cfg.MagnetUri = $src
	} else {
		$cfg.TorrentPath = [System.IO.Path]::GetFullPath($src)
	}
	$cfg.SavePath = $OutDir
	$cfg.ListenPort = $ListenPort
	$cfg.MaxPeers = $Peers
	$cfg.LogLevel = $Level
	$cfg.Sequential = $Seq
	$cfg.EnableDht = $Dht
	$cfg.SeedAfterComplete = $Seed
	$cfg.ForcedPeer = $Forced
	$cfg.EnableEncrypt = $Encrypt
	$cfg.EnableUtp = $Utp
	return $cfg
}

function Start-PowerTorrentConsole {
	param($engine)
	Write-Host '  Press Q or Escape to stop.' -ForegroundColor DarkGray
	Write-Host ''
	$isConsole = $Host.Name -eq 'ConsoleHost'
	$dashRow = 0
	if ($isConsole) {
		try { $dashRow = [Console]::CursorTop } catch { $isConsole = $false }
	}
	$engine.Start()
	$printedLogs = @{}
	try {
		while ($engine.IsRunning) {
			$s = $engine.GetStatus()
			if ($isConsole) {
				try {
					[Console]::SetCursorPosition(0, $dashRow)
					Show-TorrentDashboard $s
				} catch {
					Show-TorrentDashboard $s
				}
			} else {
				Write-Host ("[{0}] {1:0.00}%  {2}/s	 peers {3}/{4}	{5}" -f $s.State, $s.ProgressPercent, [PowerTorrent.Engine]::Fmt([long]$s.DownBytesPerSec), $s.PeersConnected, $s.PeersKnown, $s.Eta)
				foreach ($line in @($s.LogLines)) {
					if ($line -and -not $printedLogs.ContainsKey($line)) {
						$printedLogs[$line] = $true
						Write-Host $line -ForegroundColor DarkCyan
					}
				}
			}
			$pct = [Math]::Max(0, [Math]::Min(100, [int][Math]::Floor($s.ProgressPercent)))
			Write-Progress -Activity $s.Name -Status ("{0}	{1:0.00}%  {2}" -f $s.State, $s.ProgressPercent, $s.Eta) -PercentComplete $pct
			if ($isConsole) {
				try {
					while ([Console]::KeyAvailable) {
						$k = [Console]::ReadKey($true)
						if ($k.Key -eq 'Q' -or $k.Key -eq 'Escape') {
							Write-Host ''
							Write-Host 'Stopping...' -ForegroundColor Yellow
							$engine.Stop()
							break
						}
					}
				} catch { }
			}
			Start-Sleep -Milliseconds 500
		}
	} finally {
		Write-Progress -Activity 'PowerTorrent' -Completed
		try { $engine.Stop() } catch { }
	}
	$final = $engine.GetStatus()
	Write-Host ''
	Write-Host ("Finished: {0}	{1:0.00}%  down {2}	 up {3}" -f $final.State, $final.ProgressPercent, [PowerTorrent.Engine]::Fmt([long]$final.Downloaded), [PowerTorrent.Engine]::Fmt([long]$final.Uploaded)) -ForegroundColor $(if ($final.State -eq 'Complete' -or $final.State -eq 'Seeding' -or $final.State -eq 'Stopped') { 'Green' } else { 'Yellow' })
	if ($final.ErrorMessage) {
		Write-Host ("Error: {0}" -f $final.ErrorMessage) -ForegroundColor Red
		exit 1
	}
}

function Initialize-PowerTorrentNativeIcons {
	if ('PowerTorrent.IconExtractor' -as [type]) { return }
	$cs = @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media.Imaging;

namespace PowerTorrent {
	public static class WindowMaximizeFix {
		const int WM_GETMINMAXINFO = 0x0024;
		const uint MONITOR_DEFAULTTONEAREST = 2;

		[StructLayout(LayoutKind.Sequential)]
		struct POINT { public int X; public int Y; }

		[StructLayout(LayoutKind.Sequential)]
		struct MINMAXINFO {
			public POINT ptReserved;
			public POINT ptMaxSize;
			public POINT ptMaxPosition;
			public POINT ptMinTrackSize;
			public POINT ptMaxTrackSize;
		}

		[StructLayout(LayoutKind.Sequential)]
		struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

		[StructLayout(LayoutKind.Sequential)]
		struct MONITORINFO {
			public int cbSize;
			public RECT rcMonitor;
			public RECT rcWork;
			public int dwFlags;
		}

		[DllImport("user32.dll")]
		static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint dwFlags);

		[DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
		static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO lpmi);

		public static void Attach(Window window) {
			if (window == null) return;
			window.SourceInitialized += delegate {
				IntPtr hwnd = new WindowInteropHelper(window).Handle;
				HwndSource src = HwndSource.FromHwnd(hwnd);
				if (src != null) src.AddHook(Hook);
			};
		}

		static IntPtr Hook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled) {
			if (msg != WM_GETMINMAXINFO || lParam == IntPtr.Zero) return IntPtr.Zero;
			IntPtr mon = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
			if (mon == IntPtr.Zero) return IntPtr.Zero;
			MONITORINFO mi = new MONITORINFO();
			mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
			if (!GetMonitorInfo(mon, ref mi)) return IntPtr.Zero;
			MINMAXINFO mmi = (MINMAXINFO)Marshal.PtrToStructure(lParam, typeof(MINMAXINFO));
			RECT wa = mi.rcWork;
			RECT ma = mi.rcMonitor;
			mmi.ptMaxPosition.X = wa.Left - ma.Left;
			mmi.ptMaxPosition.Y = wa.Top - ma.Top;
			mmi.ptMaxSize.X = wa.Right - wa.Left;
			mmi.ptMaxSize.Y = wa.Bottom - wa.Top;
			mmi.ptMaxTrackSize.X = mmi.ptMaxSize.X;
			mmi.ptMaxTrackSize.Y = mmi.ptMaxSize.Y;
			Marshal.StructureToPtr(mmi, lParam, true);
			return IntPtr.Zero;
		}
	}

	public static class IconExtractor {
		[DllImport("Shell32.dll", EntryPoint = "ExtractIconExW", CharSet = CharSet.Unicode, ExactSpelling = true)]
		static extern int ExtractIconEx(string sFile, int iIndex, out IntPtr piLargeVersion, out IntPtr piSmallVersion, int amountIcons);

		[DllImport("user32.dll", SetLastError = true)]
		static extern bool DestroyIcon(IntPtr hIcon);

		public static BitmapSource Extract(string file, int number, bool largeIcon) {
			IntPtr large;
			IntPtr small;
			ExtractIconEx(file, number, out large, out small, 1);
			IntPtr use = largeIcon ? large : small;
			IntPtr other = largeIcon ? small : large;
			if (use == IntPtr.Zero) {
				if (other != IntPtr.Zero) DestroyIcon(other);
				return null;
			}
			try {
				BitmapSource bs = Imaging.CreateBitmapSourceFromHIcon(
					use,
					Int32Rect.Empty,
					BitmapSizeOptions.FromEmptyOptions());
				bs.Freeze();
				return bs;
			} catch {
				return null;
			} finally {
				DestroyIcon(use);
				if (other != IntPtr.Zero) DestroyIcon(other);
			}
		}

		public static Icon ExtractWinIcon(string file, int number, bool largeIcon) {
			IntPtr large;
			IntPtr small;
			ExtractIconEx(file, number, out large, out small, 1);
			IntPtr use = largeIcon ? large : small;
			IntPtr other = largeIcon ? small : large;
			if (use == IntPtr.Zero) {
				if (other != IntPtr.Zero) DestroyIcon(other);
				return null;
			}
			try {
				Icon tmp = Icon.FromHandle(use);
				return (Icon)tmp.Clone();
			} catch {
				return null;
			} finally {
				DestroyIcon(use);
				if (other != IntPtr.Zero) DestroyIcon(other);
			}
		}
	}
}
'@
	Add-Type -AssemblyName System.Drawing | Out-Null
	$refs = @(
		[System.Windows.Media.Imaging.BitmapSource].Assembly.Location,
		[System.Windows.Window].Assembly.Location,
		[System.Windows.Int32Rect].Assembly.Location,
		[System.Drawing.Icon].Assembly.Location,
		([System.Reflection.Assembly]::Load('System.Xaml, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089')).Location
	) | Select-Object -Unique
	Add-Type -TypeDefinition $cs -ReferencedAssemblies $refs -ErrorAction Stop
}

function Get-NativeWinIcon {
	param(
		[string]$File,
		[int]$Index,
		[switch]$Large
	)
	$path = [Environment]::ExpandEnvironmentVariables($File)
	if (-not (Test-Path -LiteralPath $path)) { return $null }
	try {
		return [PowerTorrent.IconExtractor]::ExtractWinIcon($path, $Index, [bool]$Large)
	} catch {
		return $null
	}
}

function Get-NativeIconBitmap {
	param(
		[string]$File,
		[int]$Index,
		[switch]$Large
	)
	$path = [Environment]::ExpandEnvironmentVariables($File)
	if (-not (Test-Path -LiteralPath $path)) { return $null }
	try {
		return [PowerTorrent.IconExtractor]::Extract($path, $Index, [bool]$Large)
	} catch {
		return $null
	}
}

function Show-PowerTorrentGui {
	param(
		[string]$InitialSource = '',
		[string]$InitialSave = '',
		[switch]$AutoStart
	)

	Add-Type -AssemblyName PresentationFramework | Out-Null
	Add-Type -AssemblyName PresentationCore | Out-Null
	Add-Type -AssemblyName WindowsBase | Out-Null
	Add-Type -AssemblyName System.Windows.Forms | Out-Null
	Add-Type -AssemblyName System.Drawing | Out-Null
	Initialize-PowerTorrentNativeIcons

	$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
		xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
		Title="PowerTorrent"
		Width="1080" Height="720"
		MinWidth="800" MinHeight="560"
		WindowStartupLocation="CenterScreen"
		WindowStyle="None"
		ResizeMode="CanResize"
		Background="{DynamicResource Theme.WindowBg}"
		FontFamily="Segoe UI" FontSize="13"
		BorderBrush="{DynamicResource Theme.Border}" BorderThickness="1"
		Foreground="{DynamicResource Theme.Text}">
  <Window.Resources>
	<SolidColorBrush x:Key="{x:Static SystemColors.HighlightBrushKey}" Color="#1E4A5C"/>
	<SolidColorBrush x:Key="{x:Static SystemColors.HighlightTextBrushKey}" Color="#E8F4F8"/>
	<SolidColorBrush x:Key="{x:Static SystemColors.InactiveSelectionHighlightBrushKey}" Color="#1A2228"/>
	<SolidColorBrush x:Key="{x:Static SystemColors.InactiveSelectionHighlightTextBrushKey}" Color="#A8C4CC"/>
	<SolidColorBrush x:Key="{x:Static SystemColors.WindowBrushKey}" Color="#141A1E"/>
	<SolidColorBrush x:Key="{x:Static SystemColors.WindowTextBrushKey}" Color="#E8F4F8"/>
	<StreamGeometry x:Key="GeoPlus">M19,13H13V19H11V13H5V11H11V5H13V11H19V13Z</StreamGeometry>
	<StreamGeometry x:Key="GeoMinus">M19,13H5V11H19V13Z</StreamGeometry>
	<StreamGeometry x:Key="GeoPause">M14,19H18V5H14M6,19H10V5H6V19Z</StreamGeometry>
	<StreamGeometry x:Key="GeoPlay">M8,5.14V19.14L19,12.14L8,5.14Z</StreamGeometry>
	<StreamGeometry x:Key="GeoStop">M18,18H6V6H18V18Z</StreamGeometry>
	<StreamGeometry x:Key="GeoMagnet">M3,7V13A9,9 0 0,0 12,22A9,9 0 0,0 21,13V7H17V13A5,5 0 0,1 12,18A5,5 0 0,1 7,13V7M17,5H21V2H17M3,5H7V2H3</StreamGeometry>
	<StreamGeometry x:Key="GeoCheck">M21,7L9,19L3.5,13.5L4.91,12.09L9,16.17L19.59,5.59L21,7Z</StreamGeometry>
	<StreamGeometry x:Key="GeoCheckMulti">M0.41,13.41L6,19L7.41,17.58L1.83,12M22.24,5.58L11.66,16.17L7.5,12L6.07,13.41L11.66,19L23.66,7M18,7L16.59,5.58L10.24,11.93L11.66,13.34L18,7Z</StreamGeometry>
	<StreamGeometry x:Key="GeoDownload">M13,2.03C17.73,2.5 21.5,6.25 21.95,11C22.5,16.5 18.5,21.38 13,21.93V19.93C16.64,19.5 19.5,16.61 19.96,12.97C20.5,8.58 17.39,4.59 13,4.05V2.05L13,2.03M11,2.06V4.06C9.57,4.26 8.22,4.84 7.1,5.74L5.67,4.26C7.19,3 9.05,2.25 11,2.06M4.26,5.67L5.69,7.1C4.8,8.23 4.24,9.58 4.05,11H2.05C2.25,9.04 3,7.19 4.26,5.67M2.06,13H4.06C4.24,14.42 4.81,15.77 5.69,16.9L4.27,18.33C3.03,16.81 2.26,14.96 2.06,13M7.1,18.37C8.23,19.25 9.58,19.82 11,20V22C9.04,21.79 7.18,21 5.67,19.74L7.1,18.37M12,16.5L7.5,12H11V8H13V12H16.5L12,16.5Z</StreamGeometry>
	<StreamGeometry x:Key="GeoUpload">M13,2.03C17.73,2.5 21.5,6.25 21.95,11C22.5,16.5 18.5,21.38 13,21.93V19.93C16.64,19.5 19.5,16.61 19.96,12.97C20.5,8.58 17.39,4.59 13,4.05V2.05L13,2.03M11,2.06V4.06C9.57,4.26 8.22,4.84 7.1,5.74L5.67,4.26C7.19,3 9.05,2.25 11,2.06M4.26,5.67L5.69,7.1C4.8,8.23 4.24,9.58 4.05,11H2.05C2.25,9.04 3,7.19 4.26,5.67M2.06,13H4.06C4.24,14.42 4.81,15.77 5.69,16.9L4.27,18.33C3.03,16.81 2.26,14.96 2.06,13M7.1,18.37C8.23,19.25 9.58,19.82 11,20V22C9.04,21.79 7.18,21 5.67,19.74L7.1,18.37M12,7.5L7.5,12H11V16H13V12H16.5L12,7.5Z</StreamGeometry>
	<StreamGeometry x:Key="GeoClock">M13,2.03V2.05L13,4.05C17.39,4.59 20.5,8.58 19.96,12.97C19.5,16.61 16.64,19.5 13,19.93V21.93C18.5,21.38 22.5,16.5 21.95,11C21.5,6.25 17.73,2.5 13,2.03M11,2.06C9.05,2.25 7.19,3 5.67,4.26L7.1,5.74C8.22,4.84 9.57,4.26 11,4.06V2.06M4.26,5.67C3,7.19 2.25,9.04 2.05,11H4.05C4.24,9.58 4.8,8.23 5.69,7.1L4.26,5.67M2.06,13C2.26,14.96 3.03,16.81 4.27,18.33L5.69,16.9C4.81,15.77 4.24,14.42 4.06,13H2.06M7.1,18.37L5.67,19.74C7.18,21 9.04,21.79 11,22V20C9.58,19.82 8.23,19.25 7.1,18.37M12.5,7V12.25L17,14.92L16.25,16.15L11,13V7H12.5Z</StreamGeometry>
	<StreamGeometry x:Key="GeoQuestion">M13 18H11V16H13V18M13 15H11C11 11.75 14 12 14 10C14 8.9 13.1 8 12 8C10.9 8 10 8.9 10 10H8C8 7.79 9.79 6 12 6C14.21 6 16 7.79 16 10C16 12.5 13 12.75 13 15M22 12C22 17.18 18.05 21.45 13 21.95V19.94C16.95 19.45 20 16.08 20 12C20 7.92 16.95 4.55 13 4.06V2.05C18.05 2.55 22 6.82 22 12M11 2.05V4.06C9.54 4.24 8.2 4.82 7.09 5.68L5.67 4.26C7.15 3.05 9 2.25 11 2.05M4.06 11H2.05C2.25 9 3.05 7.15 4.26 5.67L5.68 7.1C4.82 8.2 4.24 9.54 4.06 11M11 19.94V21.95C9 21.75 7.15 20.96 5.67 19.74L7.09 18.32C8.2 19.18 9.54 19.76 11 19.94M2.05 13H4.06C4.24 14.46 4.82 15.8 5.68 16.91L4.26 18.33C3.05 16.85 2.25 15 2.05 13Z</StreamGeometry>
	<StreamGeometry x:Key="GeoChevronLeft">M15.41,16.58L10.83,12L15.41,7.41L14,6L8,12L14,18L15.41,16.58Z</StreamGeometry>
	<StreamGeometry x:Key="GeoChevronRight">M8.59,16.58L13.17,12L8.59,7.41L10,6L16,12L10,18L8.59,16.58Z</StreamGeometry>
	<StreamGeometry x:Key="GeoGear">M12,15.5A3.5,3.5 0 0,1 8.5,12A3.5,3.5 0 0,1 12,8.5A3.5,3.5 0 0,1 15.5,12A3.5,3.5 0 0,1 12,15.5M19.43,12.97C19.47,12.65 19.5,12.33 19.5,12C19.5,11.67 19.47,11.34 19.43,11L21.54,9.37C21.73,9.22 21.78,8.95 21.66,8.73L19.66,5.27C19.54,5.05 19.27,4.96 19.05,5.05L16.56,6.05C16.04,5.66 15.5,5.32 14.87,5.07L14.5,2.42C14.46,2.18 14.25,2 14,2H10C9.75,2 9.54,2.18 9.5,2.42L9.13,5.07C8.5,5.32 7.96,5.66 7.44,6.05L4.95,5.05C4.73,4.96 4.46,5.05 4.34,5.27L2.34,8.73C2.21,8.95 2.27,9.22 2.46,9.37L4.57,11C4.53,11.34 4.5,11.67 4.5,12C4.5,12.33 4.53,12.65 4.57,12.97L2.46,14.63C2.27,14.78 2.21,15.05 2.34,15.27L4.34,18.73C4.46,18.95 4.73,19.03 4.95,18.95L7.44,17.94C7.96,18.34 8.5,18.68 9.13,18.93L9.5,21.58C9.54,21.82 9.75,22 10,22H14C14.25,22 14.46,21.82 14.5,21.58L14.87,18.93C15.5,18.67 16.04,18.34 16.56,17.94L19.05,18.95C19.27,19.03 19.54,18.95 19.66,18.73L21.66,15.27C21.78,15.05 21.73,14.78 21.54,14.63L19.43,12.97Z</StreamGeometry>
	<StreamGeometry x:Key="GeoFolder">M10,4H4C2.89,4 2,4.89 2,6V18A2,2 0 0,0 4,20H20A2,2 0 0,0 22,18V8C22,6.89 21.1,6 20,6H12L10,4Z</StreamGeometry>
	<SolidColorBrush x:Key="Theme.WindowBg" Color="#141A1E"/>
	<SolidColorBrush x:Key="Theme.Text" Color="#E8F4F8"/>
	<SolidColorBrush x:Key="Theme.Muted" Color="#A8C4CC"/>
	<SolidColorBrush x:Key="Theme.Accent" Color="#6BB3C4"/>
	<SolidColorBrush x:Key="Theme.AccentHi" Color="#8FD4E3"/>
	<SolidColorBrush x:Key="Theme.AccentDeep" Color="#1E4A5C"/>
	<SolidColorBrush x:Key="Theme.Fill" Color="#1A2228"/>
	<SolidColorBrush x:Key="Theme.FillDeep" Color="#10161A"/>
	<SolidColorBrush x:Key="Theme.Border" Color="#3D5A66"/>
	<SolidColorBrush x:Key="Theme.BorderHi" Color="#8FD4E3"/>
	<SolidColorBrush x:Key="Theme.ListBg" Color="#151C22"/>
	<SolidColorBrush x:Key="Theme.CaptionHover" Color="#2A4450"/>
	<SolidColorBrush x:Key="Theme.CaptionPress" Color="#1A3A48"/>
	<SolidColorBrush x:Key="Theme.CloseHover" Color="#C42B1C"/>
	<SolidColorBrush x:Key="Theme.ClosePress" Color="#9B2115"/>
	<SolidColorBrush x:Key="Theme.Ico" Color="#C5E8F0"/>
	<SolidColorBrush x:Key="Theme.CheckOn" Color="#1E4A5C"/>
	<SolidColorBrush x:Key="Theme.CheckMark" Color="#E8F4F8"/>
	<SolidColorBrush x:Key="Theme.Disabled" Color="#6A7A80"/>
	<SolidColorBrush x:Key="Theme.RowEven" Color="#141A1E"/>
	<SolidColorBrush x:Key="Theme.RowOdd" Color="#1E2A32"/>
	<LinearGradientBrush x:Key="HdrFace" StartPoint="0,0" EndPoint="0,1">
	  <GradientStop Color="#1A242C" Offset="0"/>
	  <GradientStop Color="#10161A" Offset="1"/>
	</LinearGradientBrush>
	<LinearGradientBrush x:Key="ToolFace" StartPoint="0,0" EndPoint="0,1">
	  <GradientStop Color="#243038" Offset="0"/>
	  <GradientStop Color="#172026" Offset="1"/>
	</LinearGradientBrush>
	<LinearGradientBrush x:Key="BarFace" StartPoint="0,0" EndPoint="0,1">
	  <GradientStop Color="#1E2A32" Offset="0"/>
	  <GradientStop Color="#141C22" Offset="1"/>
	</LinearGradientBrush>
	<LinearGradientBrush x:Key="BtnFace" StartPoint="0,0" EndPoint="0,1">
	  <GradientStop Color="#334650" Offset="0"/>
	  <GradientStop Color="#1E2C34" Offset="1"/>
	</LinearGradientBrush>
	<LinearGradientBrush x:Key="BtnHover" StartPoint="0,0" EndPoint="0,1">
	  <GradientStop Color="#3E5C68" Offset="0"/>
	  <GradientStop Color="#2A4450" Offset="1"/>
	</LinearGradientBrush>
	<LinearGradientBrush x:Key="BtnPress" StartPoint="0,0" EndPoint="0,1">
	  <GradientStop Color="#1A3A48" Offset="0"/>
	  <GradientStop Color="#122830" Offset="1"/>
	</LinearGradientBrush>
	<LinearGradientBrush x:Key="SelectFace" StartPoint="0,0" EndPoint="1,0">
	  <GradientStop Color="#245A6C" Offset="0"/>
	  <GradientStop Color="#1A3E4C" Offset="1"/>
	</LinearGradientBrush>
	<LinearGradientBrush x:Key="HoverFace" StartPoint="0,0" EndPoint="1,0">
	  <GradientStop Color="#2C4450" Offset="0"/>
	  <GradientStop Color="#1E3038" Offset="1"/>
	</LinearGradientBrush>
	<LinearGradientBrush x:Key="HeadFace" StartPoint="0,0" EndPoint="0,1">
	  <GradientStop Color="#243038" Offset="0"/>
	  <GradientStop Color="#182228" Offset="1"/>
	</LinearGradientBrush>
	<LinearGradientBrush x:Key="ProgGreen" StartPoint="0,0" EndPoint="0,1">
	  <GradientStop Color="#6EE08A" Offset="0"/>
	  <GradientStop Color="#2EA043" Offset="1"/>
	</LinearGradientBrush>
	<LinearGradientBrush x:Key="ProgYellow" StartPoint="0,0" EndPoint="0,1">
	  <GradientStop Color="#FFE066" Offset="0"/>
	  <GradientStop Color="#E0A800" Offset="1"/>
	</LinearGradientBrush>
	<LinearGradientBrush x:Key="PopFace" StartPoint="0,0" EndPoint="0,1">
	  <GradientStop Color="#243038" Offset="0"/>
	  <GradientStop Color="#161E24" Offset="1"/>
	</LinearGradientBrush>
	<Style x:Key="Ico" TargetType="Path">
	  <Setter Property="Stretch" Value="Uniform"/>
	  <Setter Property="Width" Value="14"/>
	  <Setter Property="Height" Value="14"/>
	  <Setter Property="Fill" Value="{DynamicResource Theme.Ico}"/>
	  <Setter Property="Stroke" Value="#000000"/>
	  <Setter Property="StrokeThickness" Value="0.7"/>
	  <Setter Property="StrokeLineJoin" Value="Round"/>
	  <Setter Property="StrokeStartLineCap" Value="Round"/>
	  <Setter Property="StrokeEndLineCap" Value="Round"/>
	  <Setter Property="VerticalAlignment" Value="Center"/>
	  <Setter Property="SnapsToDevicePixels" Value="True"/>
	  <Setter Property="Effect">
		<Setter.Value>
		  <DropShadowEffect Color="#000000" BlurRadius="1.2" ShadowDepth="0.4" Opacity="0.55" Direction="270"/>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style x:Key="IcoOnBtn" TargetType="Path" BasedOn="{StaticResource Ico}">
	  <Setter Property="Fill" Value="{DynamicResource Theme.Text}"/>
	  <Setter Property="Margin" Value="0,0,6,0"/>
	</Style>
	<Style x:Key="IcoFilter" TargetType="Path" BasedOn="{StaticResource Ico}">
	  <Setter Property="Stroke" Value="Transparent"/>
	  <Setter Property="StrokeThickness" Value="0"/>
	</Style>
	<Style x:Key="CaptionBtn" TargetType="Button">
	  <Setter Property="Background" Value="Transparent"/>
	  <Setter Property="BorderThickness" Value="0"/>
	  <Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="Button">
			<Border x:Name="bd" Background="{TemplateBinding Background}">
			  <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
			</Border>
			<ControlTemplate.Triggers>
			  <Trigger Property="IsMouseOver" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource Theme.CaptionHover}"/>
			  </Trigger>
			  <Trigger Property="IsPressed" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource Theme.CaptionPress}"/>
			  </Trigger>
			</ControlTemplate.Triggers>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style x:Key="CaptionCloseBtn" TargetType="Button" BasedOn="{StaticResource CaptionBtn}">
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="Button">
			<Border x:Name="bd" Background="{TemplateBinding Background}">
			  <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
			</Border>
			<ControlTemplate.Triggers>
			  <Trigger Property="IsMouseOver" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource Theme.CloseHover}"/>
			  </Trigger>
			  <Trigger Property="IsPressed" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource Theme.ClosePress}"/>
			  </Trigger>
			</ControlTemplate.Triggers>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style x:Key="DlgBtn" TargetType="Button">
	  <Setter Property="Background" Value="{DynamicResource BtnFace}"/>
	  <Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
	  <Setter Property="BorderBrush" Value="{DynamicResource Theme.Border}"/>
	  <Setter Property="BorderThickness" Value="1"/>
	  <Setter Property="Padding" Value="10,4"/>
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="Button">
			<Border x:Name="bd" Background="{TemplateBinding Background}"
					BorderBrush="{TemplateBinding BorderBrush}"
					BorderThickness="{TemplateBinding BorderThickness}"
					Padding="{TemplateBinding Padding}" CornerRadius="3" SnapsToDevicePixels="True">
			  <Border.Effect>
				<DropShadowEffect Color="#000000" BlurRadius="4" ShadowDepth="1" Opacity="0.32" Direction="270"/>
			  </Border.Effect>
			  <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
			</Border>
			<ControlTemplate.Triggers>
			  <Trigger Property="IsMouseOver" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource BtnHover}"/>
				<Setter TargetName="bd" Property="BorderBrush" Value="{DynamicResource Theme.AccentHi}"/>
			  </Trigger>
			  <Trigger Property="IsPressed" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource BtnPress}"/>
				<Setter TargetName="bd" Property="BorderBrush" Value="{DynamicResource Theme.AccentHi}"/>
			  </Trigger>
			  <Trigger Property="IsEnabled" Value="False">
				<Setter Property="Foreground" Value="{DynamicResource Theme.Disabled}"/>
				<Setter TargetName="bd" Property="BorderBrush" Value="{DynamicResource Theme.Border}"/>
			  </Trigger>
			</ControlTemplate.Triggers>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style TargetType="Button" BasedOn="{StaticResource DlgBtn}"/>
	<Style TargetType="TextBox">
	  <Setter Property="Background" Value="{DynamicResource Theme.Fill}"/>
	  <Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
	  <Setter Property="BorderBrush" Value="{DynamicResource Theme.Border}"/>
	  <Setter Property="CaretBrush" Value="{DynamicResource Theme.AccentHi}"/>
	  <Setter Property="SelectionBrush" Value="{DynamicResource Theme.AccentDeep}"/>
	  <Setter Property="BorderThickness" Value="1"/>
	  <Setter Property="Padding" Value="6,2"/>
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="TextBox">
			<Border x:Name="bd" Background="{TemplateBinding Background}"
					BorderBrush="{TemplateBinding BorderBrush}"
					BorderThickness="{TemplateBinding BorderThickness}"
					CornerRadius="2" SnapsToDevicePixels="True">
			  <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"/>
			</Border>
			<ControlTemplate.Triggers>
			  <Trigger Property="IsMouseOver" Value="True">
				<Setter TargetName="bd" Property="BorderBrush" Value="{DynamicResource Theme.Accent}"/>
			  </Trigger>
			  <Trigger Property="IsFocused" Value="True">
				<Setter TargetName="bd" Property="BorderBrush" Value="{DynamicResource Theme.AccentHi}"/>
			  </Trigger>
			  <Trigger Property="IsEnabled" Value="False">
				<Setter Property="Foreground" Value="{DynamicResource Theme.Disabled}"/>
			  </Trigger>
			</ControlTemplate.Triggers>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style TargetType="CheckBox">
	  <Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
	  <Setter Property="Background" Value="{DynamicResource Theme.Fill}"/>
	  <Setter Property="BorderBrush" Value="{DynamicResource Theme.Border}"/>
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="CheckBox">
			<StackPanel Orientation="Horizontal">
			  <Border x:Name="box" Width="16" Height="16" Background="{DynamicResource Theme.Fill}"
					  BorderBrush="{DynamicResource Theme.Border}" BorderThickness="1" CornerRadius="2"
					  Margin="0,0,8,0" VerticalAlignment="Center" SnapsToDevicePixels="True">
				<Border.Effect>
				  <DropShadowEffect Color="#000000" BlurRadius="2" ShadowDepth="0.6" Opacity="0.4" Direction="270"/>
				</Border.Effect>
				<Path x:Name="check" Data="{StaticResource GeoCheck}" Fill="{DynamicResource Theme.CheckMark}"
					  Stroke="#000000" StrokeThickness="0.7" StrokeLineJoin="Round"
					  Stretch="Uniform" Margin="2" Visibility="Collapsed"/>
			  </Border>
			  <ContentPresenter VerticalAlignment="Center" RecognizesAccessKey="True"/>
			</StackPanel>
			<ControlTemplate.Triggers>
			  <Trigger Property="IsChecked" Value="True">
				<Setter TargetName="check" Property="Visibility" Value="Visible"/>
				<Setter TargetName="box" Property="Background" Value="{DynamicResource Theme.CheckOn}"/>
				<Setter TargetName="box" Property="BorderBrush" Value="{DynamicResource Theme.Accent}"/>
			  </Trigger>
			  <Trigger Property="IsMouseOver" Value="True">
				<Setter TargetName="box" Property="BorderBrush" Value="{DynamicResource Theme.AccentHi}"/>
			  </Trigger>
			  <Trigger Property="IsPressed" Value="True">
				<Setter TargetName="box" Property="Background" Value="{DynamicResource Theme.CaptionPress}"/>
			  </Trigger>
			</ControlTemplate.Triggers>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style TargetType="TextBlock">
	  <Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
	</Style>
	<Style TargetType="ListBoxItem">
	  <Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
	  <Setter Property="Background" Value="Transparent"/>
	  <Setter Property="Padding" Value="10,7"/>
	  <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="ListBoxItem">
			<Border x:Name="bd" Background="{TemplateBinding Background}" SnapsToDevicePixels="True">
			  <DockPanel>
				<Border x:Name="accent" Width="3" Background="Transparent" DockPanel.Dock="Left"/>
				<ContentPresenter Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
			  </DockPanel>
			</Border>
			<ControlTemplate.Triggers>
			  <Trigger Property="IsMouseOver" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource HoverFace}"/>
			  </Trigger>
			  <Trigger Property="IsSelected" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource SelectFace}"/>
				<Setter TargetName="accent" Property="Background" Value="{DynamicResource Theme.AccentHi}"/>
				<Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
			  </Trigger>
			  <MultiTrigger>
				<MultiTrigger.Conditions>
				  <Condition Property="IsSelected" Value="True"/>
				  <Condition Property="IsMouseOver" Value="True"/>
				</MultiTrigger.Conditions>
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource BtnHover}"/>
				<Setter TargetName="accent" Property="Background" Value="{DynamicResource Theme.Ico}"/>
			  </MultiTrigger>
			</ControlTemplate.Triggers>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style TargetType="ListViewItem">
	  <Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
	  <Setter Property="Background" Value="Transparent"/>
	  <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
	  <Setter Property="SnapsToDevicePixels" Value="True"/>
	  <Setter Property="Focusable" Value="True"/>
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="ListViewItem">
			<Border x:Name="bd" Background="{TemplateBinding Background}" Padding="0,2" SnapsToDevicePixels="True">
			  <GridViewRowPresenter Content="{TemplateBinding Content}"
									Columns="{TemplateBinding GridView.ColumnCollection}"
									VerticalAlignment="Center"/>
			</Border>
			<ControlTemplate.Triggers>
			  <Trigger Property="IsMouseOver" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource HoverFace}"/>
			  </Trigger>
			  <Trigger Property="IsSelected" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource SelectFace}"/>
				<Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
			  </Trigger>
			  <MultiTrigger>
				<MultiTrigger.Conditions>
				  <Condition Property="IsSelected" Value="True"/>
				  <Condition Property="IsMouseOver" Value="True"/>
				</MultiTrigger.Conditions>
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource BtnHover}"/>
			  </MultiTrigger>
			</ControlTemplate.Triggers>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style x:Key="PtStripeListViewItem" TargetType="ListViewItem" BasedOn="{StaticResource {x:Type ListViewItem}}">
	  <Style.Triggers>
		<Trigger Property="ItemsControl.AlternationIndex" Value="0">
		  <Setter Property="Background" Value="{DynamicResource Theme.RowEven}"/>
		</Trigger>
		<Trigger Property="ItemsControl.AlternationIndex" Value="1">
		  <Setter Property="Background" Value="{DynamicResource Theme.RowOdd}"/>
		</Trigger>
	  </Style.Triggers>
	</Style>
	<Style x:Key="PtStripeListBoxItem" TargetType="ListBoxItem" BasedOn="{StaticResource {x:Type ListBoxItem}}">
	  <Setter Property="Padding" Value="10,5"/>
	  <Style.Triggers>
		<Trigger Property="ItemsControl.AlternationIndex" Value="0">
		  <Setter Property="Background" Value="{DynamicResource Theme.RowEven}"/>
		</Trigger>
		<Trigger Property="ItemsControl.AlternationIndex" Value="1">
		  <Setter Property="Background" Value="{DynamicResource Theme.RowOdd}"/>
		</Trigger>
	  </Style.Triggers>
	</Style>
	<Style x:Key="InfoRowEven" TargetType="Border">
	  <Setter Property="Background" Value="{DynamicResource Theme.RowEven}"/>
	  <Setter Property="Padding" Value="10,6"/>
	</Style>
	<Style x:Key="InfoRowOdd" TargetType="Border">
	  <Setter Property="Background" Value="{DynamicResource Theme.RowOdd}"/>
	  <Setter Property="Padding" Value="10,6"/>
	</Style>
	<Style TargetType="ListBox">
	  <Setter Property="Background" Value="{DynamicResource Theme.ListBg}"/>
	  <Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
	  <Setter Property="BorderBrush" Value="{DynamicResource Theme.Border}"/>
	  <Setter Property="BorderThickness" Value="0"/>
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="ListBox">
			<Border Background="{TemplateBinding Background}"
					BorderBrush="{TemplateBinding BorderBrush}"
					BorderThickness="{TemplateBinding BorderThickness}"
					SnapsToDevicePixels="True">
			  <ScrollViewer Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}"
							Focusable="False" HorizontalScrollBarVisibility="Disabled"
							VerticalScrollBarVisibility="Auto">
				<ItemsPresenter/>
			  </ScrollViewer>
			</Border>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style x:Key="PtListView" TargetType="ListView">
	  <Setter Property="Background" Value="{DynamicResource Theme.WindowBg}"/>
	  <Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
	  <Setter Property="BorderThickness" Value="0"/>
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="ListView">
			<Border Background="{TemplateBinding Background}"
					BorderBrush="{TemplateBinding BorderBrush}"
					BorderThickness="{TemplateBinding BorderThickness}"
					SnapsToDevicePixels="True">
			  <ScrollViewer Style="{DynamicResource {x:Static GridView.GridViewScrollViewerStyleKey}}"
							Background="{TemplateBinding Background}"
							Padding="{TemplateBinding Padding}">
				<ItemsPresenter SnapsToDevicePixels="{TemplateBinding SnapsToDevicePixels}"/>
			  </ScrollViewer>
			</Border>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style TargetType="ListView" BasedOn="{StaticResource PtListView}"/>
	<Style x:Key="{x:Static GridView.GridViewStyleKey}" TargetType="ListView" BasedOn="{StaticResource PtListView}"/>
	<Style x:Key="{x:Static GridView.GridViewItemContainerStyleKey}" TargetType="ListViewItem" BasedOn="{StaticResource {x:Type ListViewItem}}"/>
	<Style TargetType="GridViewColumnHeader">
	  <Setter Property="Background" Value="{DynamicResource HeadFace}"/>
	  <Setter Property="Foreground" Value="{DynamicResource Theme.Muted}"/>
	  <Setter Property="Padding" Value="6,5"/>
	  <Setter Property="HorizontalContentAlignment" Value="Left"/>
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="GridViewColumnHeader">
			<Grid>
			  <Border x:Name="bd" Background="{TemplateBinding Background}"
					  BorderBrush="{DynamicResource Theme.Border}" BorderThickness="0,0,1,1"
					  Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True">
				<ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
								  VerticalAlignment="Center"/>
			  </Border>
			  <Thumb x:Name="PART_HeaderGripper" HorizontalAlignment="Right" Width="8">
				<Thumb.Template>
				  <ControlTemplate TargetType="Thumb">
					<Border Background="Transparent" Width="8"/>
				  </ControlTemplate>
				</Thumb.Template>
			  </Thumb>
			</Grid>
			<ControlTemplate.Triggers>
			  <Trigger Property="IsMouseOver" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource BtnHover}"/>
				<Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
			  </Trigger>
			  <Trigger Property="IsPressed" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource BtnPress}"/>
			  </Trigger>
			  <Trigger Property="Role" Value="Padding">
				<Setter TargetName="PART_HeaderGripper" Property="Visibility" Value="Collapsed"/>
			  </Trigger>
			</ControlTemplate.Triggers>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style TargetType="TabItem">
	  <Setter Property="Foreground" Value="{DynamicResource Theme.Muted}"/>
	  <Setter Property="Background" Value="Transparent"/>
	  <Setter Property="Padding" Value="12,6"/>
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="TabItem">
			<Border x:Name="bd" Background="{TemplateBinding Background}"
					Padding="{TemplateBinding Padding}" BorderThickness="0,0,0,2"
					BorderBrush="Transparent" SnapsToDevicePixels="True">
			  <ContentPresenter ContentSource="Header" HorizontalAlignment="Center" VerticalAlignment="Center"/>
			</Border>
			<ControlTemplate.Triggers>
			  <Trigger Property="IsMouseOver" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource HoverFace}"/>
				<Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
			  </Trigger>
			  <Trigger Property="IsSelected" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource BarFace}"/>
				<Setter TargetName="bd" Property="BorderBrush" Value="{DynamicResource Theme.AccentHi}"/>
				<Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
			  </Trigger>
			</ControlTemplate.Triggers>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style TargetType="TabControl">
	  <Setter Property="Background" Value="{DynamicResource Theme.WindowBg}"/>
	  <Setter Property="BorderThickness" Value="0"/>
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="TabControl">
			<Grid>
			  <Grid.RowDefinitions>
				<RowDefinition Height="Auto"/>
				<RowDefinition Height="*"/>
			  </Grid.RowDefinitions>
			  <TabPanel Grid.Row="0" IsItemsHost="True" Background="{DynamicResource Theme.FillDeep}"/>
			  <Border Grid.Row="1" Background="{TemplateBinding Background}">
				<ContentPresenter ContentSource="SelectedContent"/>
			  </Border>
			</Grid>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style TargetType="GridSplitter">
	  <Setter Property="Background" Value="{DynamicResource Theme.Border}"/>
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="GridSplitter">
			<Border x:Name="bd" Background="{TemplateBinding Background}"/>
			<ControlTemplate.Triggers>
			  <Trigger Property="IsMouseOver" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource Theme.Accent}"/>
			  </Trigger>
			  <Trigger Property="IsDragging" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource Theme.AccentHi}"/>
			  </Trigger>
			</ControlTemplate.Triggers>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style x:Key="ThemeScrollThumb" TargetType="Thumb">
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="Thumb">
			<Border x:Name="bd" Background="{DynamicResource Theme.Border}" CornerRadius="3" Margin="1"/>
			<ControlTemplate.Triggers>
			  <Trigger Property="IsMouseOver" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource Theme.Accent}"/>
			  </Trigger>
			  <Trigger Property="IsDragging" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource Theme.AccentHi}"/>
			  </Trigger>
			</ControlTemplate.Triggers>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style x:Key="ThemeScrollPage" TargetType="RepeatButton">
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="RepeatButton">
			<Border Background="Transparent"/>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style TargetType="ScrollBar">
	  <Setter Property="Background" Value="{DynamicResource Theme.FillDeep}"/>
	  <Setter Property="Width" Value="10"/>
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="ScrollBar">
			<Grid Background="{TemplateBinding Background}">
			  <Track x:Name="PART_Track" IsDirectionReversed="True">
				<Track.DecreaseRepeatButton>
				  <RepeatButton Command="ScrollBar.PageUpCommand" Style="{StaticResource ThemeScrollPage}"/>
				</Track.DecreaseRepeatButton>
				<Track.Thumb>
				  <Thumb Style="{StaticResource ThemeScrollThumb}"/>
				</Track.Thumb>
				<Track.IncreaseRepeatButton>
				  <RepeatButton Command="ScrollBar.PageDownCommand" Style="{StaticResource ThemeScrollPage}"/>
				</Track.IncreaseRepeatButton>
			  </Track>
			</Grid>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	  <Style.Triggers>
		<Trigger Property="Orientation" Value="Horizontal">
		  <Setter Property="Width" Value="Auto"/>
		  <Setter Property="Height" Value="10"/>
		  <Setter Property="Template">
			<Setter.Value>
			  <ControlTemplate TargetType="ScrollBar">
				<Grid Background="{TemplateBinding Background}">
				  <Track x:Name="PART_Track" IsDirectionReversed="False">
					<Track.DecreaseRepeatButton>
					  <RepeatButton Command="ScrollBar.PageLeftCommand" Style="{StaticResource ThemeScrollPage}"/>
					</Track.DecreaseRepeatButton>
					<Track.Thumb>
					  <Thumb Style="{StaticResource ThemeScrollThumb}"/>
					</Track.Thumb>
					<Track.IncreaseRepeatButton>
					  <RepeatButton Command="ScrollBar.PageRightCommand" Style="{StaticResource ThemeScrollPage}"/>
					</Track.IncreaseRepeatButton>
				  </Track>
				</Grid>
			  </ControlTemplate>
			</Setter.Value>
		  </Setter>
		</Trigger>
	  </Style.Triggers>
	</Style>
	<Style TargetType="ToolTip">
	  <Setter Property="Background" Value="{DynamicResource Theme.WindowBg}"/>
	  <Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
	  <Setter Property="BorderBrush" Value="{DynamicResource Theme.Border}"/>
	  <Setter Property="BorderThickness" Value="1"/>
	  <Setter Property="Padding" Value="8,5"/>
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="ToolTip">
			<Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
					BorderThickness="{TemplateBinding BorderThickness}" Padding="{TemplateBinding Padding}" CornerRadius="2">
			  <Border.Effect>
				<DropShadowEffect Color="#041018" BlurRadius="10" ShadowDepth="2" Opacity="0.4" Direction="270"/>
			  </Border.Effect>
			  <ContentPresenter/>
			</Border>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style TargetType="ContextMenu">
	  <Setter Property="Background" Value="{DynamicResource Theme.WindowBg}"/>
	  <Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
	  <Setter Property="BorderBrush" Value="{DynamicResource Theme.Border}"/>
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="ContextMenu">
			<Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
					BorderThickness="1" Padding="4,6" CornerRadius="2">
			  <Border.Effect>
				<DropShadowEffect Color="#041018" BlurRadius="12" ShadowDepth="2" Opacity="0.4" Direction="270"/>
			  </Border.Effect>
			  <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Cycle"/>
			</Border>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style TargetType="MenuItem">
	  <Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
	  <Setter Property="Padding" Value="8,6"/>
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="MenuItem">
			<Border x:Name="bd" Background="Transparent" Padding="{TemplateBinding Padding}">
			  <DockPanel>
				<ContentPresenter DockPanel.Dock="Left" ContentSource="Icon" Width="18" Margin="0,0,8,0"
								  VerticalAlignment="Center"/>
				<ContentPresenter ContentSource="Header" VerticalAlignment="Center"/>
			  </DockPanel>
			</Border>
			<ControlTemplate.Triggers>
			  <Trigger Property="IsHighlighted" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource HoverFace}"/>
			  </Trigger>
			  <Trigger Property="IsEnabled" Value="False">
				<Setter Property="Foreground" Value="{DynamicResource Theme.Disabled}"/>
			  </Trigger>
			</ControlTemplate.Triggers>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style TargetType="Separator">
	  <Setter Property="Margin" Value="8,4"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="Separator">
			<Border Height="1" Background="{DynamicResource Theme.Border}"/>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style TargetType="ComboBox">
	  <Setter Property="Background" Value="{DynamicResource Theme.Fill}"/>
	  <Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
	  <Setter Property="BorderBrush" Value="{DynamicResource Theme.Border}"/>
	  <Setter Property="Height" Value="26"/>
	  <Setter Property="Padding" Value="6,2"/>
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="ComboBox">
			<Grid>
			  <ToggleButton x:Name="toggle" Focusable="False" ClickMode="Press"
							IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
				<ToggleButton.Template>
				  <ControlTemplate TargetType="ToggleButton">
					<Border x:Name="cbd" Background="{DynamicResource Theme.Fill}"
							BorderBrush="{DynamicResource Theme.Border}" BorderThickness="1" CornerRadius="2">
					  <Path HorizontalAlignment="Right" Margin="0,0,8,0" VerticalAlignment="Center"
							Data="{StaticResource GeoChevronRight}" Fill="{DynamicResource Theme.Ico}"
							Width="10" Height="10" Stretch="Uniform" RenderTransformOrigin="0.5,0.5">
						<Path.RenderTransform>
						  <RotateTransform Angle="90"/>
						</Path.RenderTransform>
					  </Path>
					</Border>
					<ControlTemplate.Triggers>
					  <Trigger Property="IsMouseOver" Value="True">
						<Setter TargetName="cbd" Property="BorderBrush" Value="{DynamicResource Theme.Accent}"/>
					  </Trigger>
					  <Trigger Property="IsChecked" Value="True">
						<Setter TargetName="cbd" Property="BorderBrush" Value="{DynamicResource Theme.AccentHi}"/>
					  </Trigger>
					</ControlTemplate.Triggers>
				  </ControlTemplate>
				</ToggleButton.Template>
			  </ToggleButton>
			  <ContentPresenter Margin="8,0,22,0" VerticalAlignment="Center" HorizontalAlignment="Left"
								Content="{TemplateBinding SelectionBoxItem}"
								ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
								IsHitTestVisible="False"
								TextElement.Foreground="{DynamicResource Theme.Text}"/>
			  <Popup IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom" AllowsTransparency="True"
					 PopupAnimation="Fade">
				<Border Background="{DynamicResource Theme.WindowBg}" BorderBrush="{DynamicResource Theme.Border}"
						BorderThickness="1" MinWidth="{TemplateBinding ActualWidth}" CornerRadius="2" Padding="0,4">
				  <Border.Effect>
					<DropShadowEffect Color="#041018" BlurRadius="12" ShadowDepth="2" Opacity="0.4" Direction="270"/>
				  </Border.Effect>
				  <ScrollViewer MaxHeight="220">
					<ItemsPresenter/>
				  </ScrollViewer>
				</Border>
			  </Popup>
			</Grid>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style TargetType="ComboBoxItem">
	  <Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
	  <Setter Property="Padding" Value="8,5"/>
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="ComboBoxItem">
			<Border x:Name="bd" Background="Transparent" Padding="{TemplateBinding Padding}">
			  <ContentPresenter/>
			</Border>
			<ControlTemplate.Triggers>
			  <Trigger Property="IsHighlighted" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource HoverFace}"/>
			  </Trigger>
			  <Trigger Property="IsSelected" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource SelectFace}"/>
			  </Trigger>
			</ControlTemplate.Triggers>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style TargetType="ProgressBar">
	  <Setter Property="Background" Value="{DynamicResource Theme.FillDeep}"/>
	  <Setter Property="Foreground" Value="{DynamicResource ProgGreen}"/>
	  <Setter Property="BorderThickness" Value="0"/>
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="ProgressBar">
			<Border Background="{TemplateBinding Background}" CornerRadius="3" ClipToBounds="True" BorderBrush="{DynamicResource Theme.Border}" BorderThickness="1">
			  <Border.Effect>
				<DropShadowEffect Color="#000000" BlurRadius="2" ShadowDepth="0.5" Opacity="0.35" Direction="270"/>
			  </Border.Effect>
			  <Grid>
				<Rectangle x:Name="PART_Track" Fill="Transparent"/>
				<Decorator x:Name="PART_Indicator" HorizontalAlignment="Left">
				  <Border Background="{TemplateBinding Foreground}" CornerRadius="2"/>
				</Decorator>
			  </Grid>
			</Border>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	  <Style.Triggers>
		<DataTrigger Binding="{Binding Status}" Value="Hashing">
		  <Setter Property="Foreground" Value="{DynamicResource ProgYellow}"/>
		</DataTrigger>
		<DataTrigger Binding="{Binding Status}" Value="Paused">
		  <Setter Property="Foreground" Value="{DynamicResource ProgYellow}"/>
		</DataTrigger>
	  </Style.Triggers>
	</Style>
  </Window.Resources>
  <DockPanel Background="{DynamicResource Theme.WindowBg}">
	<Border x:Name="hdrBar" DockPanel.Dock="Top" Background="{DynamicResource HdrFace}" Height="32">
	  <Grid>
		<Grid.ColumnDefinitions>
		  <ColumnDefinition Width="Auto"/>
		  <ColumnDefinition Width="*"/>
		  <ColumnDefinition Width="Auto"/>
		</Grid.ColumnDefinitions>
		<Image x:Name="imgPlanet" Width="20" Height="20" Margin="10,0,8,0"
			   VerticalAlignment="Center" RenderOptions.BitmapScalingMode="NearestNeighbor"
			   SnapsToDevicePixels="True"/>
		<StackPanel Grid.Column="1" VerticalAlignment="Center">
		  <TextBlock Text="PowerTorrent" Foreground="{DynamicResource Theme.Text}" FontSize="13" FontWeight="SemiBold"/>
		</StackPanel>
		<StackPanel Grid.Column="2" Orientation="Horizontal">
		  <Button x:Name="btnWinMin" Style="{StaticResource CaptionBtn}" Width="46" Height="32" Padding="0" ToolTip="Minimize">
			<Path Stroke="{DynamicResource Theme.Text}" StrokeThickness="1" Fill="Transparent" Width="10" Height="10" Stretch="None"
				  Data="M0,5 L10,5">
			  <Path.Effect>
				<DropShadowEffect Color="#000000" BlurRadius="1" ShadowDepth="0" Opacity="0.35"/>
			  </Path.Effect>
			</Path>
		  </Button>
		  <Button x:Name="btnWinMax" Style="{StaticResource CaptionBtn}" Width="46" Height="32" Padding="0" ToolTip="Maximize">
			<Path x:Name="pathWinMax" Stroke="{DynamicResource Theme.Text}" StrokeThickness="1" Fill="Transparent" Width="10" Height="10"
				  Stretch="Uniform" Data="M1,1 H9 V9 H1 Z">
			  <Path.Effect>
				<DropShadowEffect Color="#000000" BlurRadius="1" ShadowDepth="0" Opacity="0.35"/>
			  </Path.Effect>
			</Path>
		  </Button>
		  <Button x:Name="btnWinClose" Style="{StaticResource CaptionCloseBtn}" Width="46" Height="32" Padding="0" ToolTip="Close">
			<Path x:Name="pathWinClose" Stroke="{DynamicResource Theme.Text}" StrokeThickness="1" Fill="Transparent" Width="10" Height="10"
				  Stretch="None" Data="M0,0 L10,10 M10,0 L0,10">
			  <Path.Effect>
				<DropShadowEffect Color="#000000" BlurRadius="1" ShadowDepth="0" Opacity="0.35"/>
			  </Path.Effect>
			</Path>
		  </Button>
		</StackPanel>
	  </Grid>
	</Border>
	<Border DockPanel.Dock="Top" Background="{DynamicResource ToolFace}" Padding="8,6">
	  <Border.Effect>
		<DropShadowEffect Color="#000000" BlurRadius="6" ShadowDepth="1" Opacity="0.28" Direction="270"/>
	  </Border.Effect>
	  <Grid>
	  <DockPanel>
		<Button x:Name="btnAddFile" Style="{StaticResource DlgBtn}" Margin="0,0,6,0" ToolTip="Add torrent">
		  <StackPanel Orientation="Horizontal">
			<Path Style="{StaticResource IcoOnBtn}" Data="{StaticResource GeoPlus}"/>
			<TextBlock Text="Add torrent" VerticalAlignment="Center"/>
		  </StackPanel>
		</Button>
		<Button x:Name="btnAddMagnet" Style="{StaticResource DlgBtn}" Margin="0,0,6,0" ToolTip="Add magnet">
		  <StackPanel Orientation="Horizontal">
			<Path Style="{StaticResource IcoOnBtn}" Data="{StaticResource GeoMagnet}"/>
			<TextBlock Text="Add magnet" VerticalAlignment="Center"/>
		  </StackPanel>
		</Button>
		<Button x:Name="btnPlayPause" Style="{StaticResource DlgBtn}" Margin="0,0,6,0" ToolTip="Pause" Visibility="Collapsed">
		  <StackPanel Orientation="Horizontal">
			<Path x:Name="icoPlayPause" Style="{StaticResource IcoOnBtn}" Data="{StaticResource GeoPause}"/>
			<TextBlock x:Name="txtPlayPause" Text="Pause" VerticalAlignment="Center"/>
		  </StackPanel>
		</Button>
		<Button x:Name="btnStop" Style="{StaticResource DlgBtn}" Margin="0,0,6,0" ToolTip="Stop" Visibility="Collapsed">
		  <StackPanel Orientation="Horizontal">
			<Path Style="{StaticResource IcoOnBtn}" Data="{StaticResource GeoStop}"/>
			<TextBlock Text="Stop" VerticalAlignment="Center"/>
		  </StackPanel>
		</Button>
		<Button x:Name="btnRemove" Style="{StaticResource DlgBtn}" Margin="0,0,16,0" ToolTip="Remove" Visibility="Collapsed">
		  <StackPanel Orientation="Horizontal">
			<Path Style="{StaticResource IcoOnBtn}" Data="{StaticResource GeoMinus}"/>
			<TextBlock Text="Remove" VerticalAlignment="Center"/>
		  </StackPanel>
		</Button>
		<TextBlock Text="Save to" VerticalAlignment="Center" Foreground="{DynamicResource Theme.Muted}" Margin="0,0,6,0"/>
		<Button x:Name="btnOptions" Style="{StaticResource DlgBtn}" DockPanel.Dock="Right" Width="32" Padding="0" Margin="6,0,0,0" ToolTip="Options">
		  <Path Style="{StaticResource IcoOnBtn}" Margin="0" Width="14" Height="14" Data="{StaticResource GeoGear}"/>
		</Button>
		<TextBox x:Name="txtSave" Height="26" IsReadOnly="True" VerticalContentAlignment="Center" ToolTip="Default save path — change in Options"/>
	  </DockPanel>
		<Popup x:Name="popOptions" Placement="Bottom" PlacementTarget="{Binding ElementName=btnOptions}"
			   StaysOpen="True" AllowsTransparency="True" PopupAnimation="Fade" HorizontalOffset="-280">
		  <Border Background="{DynamicResource Theme.WindowBg}" BorderBrush="{DynamicResource Theme.Border}"
				  BorderThickness="1" CornerRadius="2" Width="340">
			<Border.Effect>
			  <DropShadowEffect Color="#041018" BlurRadius="16" ShadowDepth="3" Opacity="0.45" Direction="270"/>
			</Border.Effect>
			<DockPanel>
			  <Border DockPanel.Dock="Top" Background="{DynamicResource HdrFace}" Padding="12,8">
				<TextBlock Text="Options" FontWeight="SemiBold"/>
			  </Border>
			  <ScrollViewer MaxHeight="520" VerticalScrollBarVisibility="Auto">
				<StackPanel Margin="14,12">
				  <TextBlock Text="Default save path" FontWeight="SemiBold" Margin="0,0,0,6"/>
				  <DockPanel Margin="0,0,0,12">
					<Button x:Name="btnBrowseDir" Style="{StaticResource DlgBtn}" DockPanel.Dock="Right" Width="32" Padding="0" Margin="6,0,0,0" ToolTip="Browse">
					  <Path Style="{StaticResource IcoOnBtn}" Margin="0" Width="14" Height="14" Data="{StaticResource GeoFolder}"/>
					</Button>
					<TextBox x:Name="txtSaveFlyout" Height="24" VerticalContentAlignment="Center" Padding="4,1"/>
				  </DockPanel>
				  <DockPanel Margin="0,0,0,10">
					<TextBlock Text="Theme" Width="80" VerticalAlignment="Center"/>
					<ComboBox x:Name="cmbTheme"/>
				  </DockPanel>
				  <CheckBox x:Name="chkDht" Content="DHT" IsChecked="True" Margin="0,0,0,8"/>
				  <CheckBox x:Name="chkEncrypt" Content="MSE encryption" IsChecked="True" Margin="0,0,0,8"/>
				  <CheckBox x:Name="chkUtp" Content="uTP" IsChecked="True" Margin="0,0,0,8"/>
				  <CheckBox x:Name="chkSeq" Content="Sequential download" Margin="0,0,0,8"/>
				  <CheckBox x:Name="chkSeed" Content="Seed when done" IsChecked="True" Margin="0,0,0,8"/>
				  <CheckBox x:Name="chkCloseToTray" Content="Close to tray" IsChecked="False" Margin="0,0,0,12"/>
				  <Border Height="1" Background="{DynamicResource Theme.Border}" Margin="0,2,0,12"/>
				  <TextBlock Text="VPN" FontWeight="SemiBold" Margin="0,0,0,6"/>
				  <TextBlock x:Name="lblVpnStatus" Foreground="{DynamicResource Theme.Muted}" FontSize="11" Margin="0,0,0,8"
							 TextWrapping="Wrap" Text="No config imported."/>
				  <CheckBox x:Name="chkVpnRequire" Content="Killswitch" IsChecked="True" Margin="0,0,0,8"/>
				  <Button x:Name="btnVpnImport" Style="{StaticResource DlgBtn}" HorizontalAlignment="Stretch" Margin="0,0,0,6">
					<StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
					  <Path Style="{StaticResource IcoOnBtn}" Data="{StaticResource GeoFolder}"/>
					  <TextBlock Text="Import .conf / .ovpn" VerticalAlignment="Center"/>
					</StackPanel>
				  </Button>
				  <DockPanel Margin="0,0,0,12">
					<Button x:Name="btnVpnStop" Style="{StaticResource DlgBtn}" DockPanel.Dock="Right" MinWidth="90" Margin="6,0,0,0">
					  <TextBlock Text="Disconnect" VerticalAlignment="Center"/>
					</Button>
					<Button x:Name="btnVpnConnect" Style="{StaticResource DlgBtn}" HorizontalAlignment="Stretch">
					  <TextBlock Text="Connect" VerticalAlignment="Center"/>
					</Button>
				  </DockPanel>
				  <DockPanel Margin="0,0,0,8">
					<TextBlock Text="Port" Width="80" VerticalAlignment="Center"/>
					<TextBox x:Name="txtPort" Height="24" Text="6881" VerticalContentAlignment="Center" Padding="4,1"/>
				  </DockPanel>
				  <DockPanel Margin="0,0,0,10">
					<TextBlock Text="Max peers" Width="80" VerticalAlignment="Center" ToolTip="Per torrent. Session total is capped at 500 across all torrents."/>
					<TextBox x:Name="txtPeers" Height="24" Text="80" VerticalContentAlignment="Center" Padding="4,1"
							 ToolTip="Per torrent. Session total is capped at 500 across all torrents."/>
				  </DockPanel>
				  <Button x:Name="btnSaveOptions" Style="{StaticResource DlgBtn}" HorizontalAlignment="Stretch"
						  Margin="0,0,0,12">
					<StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
					  <Path Style="{StaticResource IcoOnBtn}" Data="{StaticResource GeoCheck}"/>
					  <TextBlock Text="Save options" VerticalAlignment="Center"/>
					</StackPanel>
				  </Button>
				  <Border Height="1" Background="{DynamicResource Theme.Border}" Margin="0,2,0,12"/>
				  <TextBlock Text="File associations" FontWeight="SemiBold" Margin="0,0,0,8"/>
				  <TextBlock x:Name="lblAssoc" Foreground="{DynamicResource Theme.Muted}" FontSize="11" Margin="0,0,0,8"
							 TextWrapping="Wrap" Text="magnet: not registered"/>
				  <Button x:Name="btnRegister" Style="{StaticResource DlgBtn}"
						  HorizontalAlignment="Stretch" Margin="0,0,0,6">
					<StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
					  <Path Style="{StaticResource IcoOnBtn}" Data="{StaticResource GeoMagnet}"/>
					  <TextBlock Text="Register magnet" VerticalAlignment="Center"/>
					</StackPanel>
				  </Button>
				  <Button x:Name="btnRegisterTorrent" Style="{StaticResource DlgBtn}"
						  HorizontalAlignment="Stretch" Margin="0,0,0,6">
					<StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
					  <Path Style="{StaticResource IcoOnBtn}" Data="{StaticResource GeoCheckMulti}"/>
					  <TextBlock Text="Register .torrent" VerticalAlignment="Center"/>
					</StackPanel>
				  </Button>
				  <Button x:Name="btnUnregister" Style="{StaticResource DlgBtn}" HorizontalAlignment="Stretch">
					<StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
					  <Path Style="{StaticResource IcoOnBtn}" Data="{StaticResource GeoMinus}"/>
					  <TextBlock Text="Remove associations" VerticalAlignment="Center"/>
					</StackPanel>
				  </Button>
				</StackPanel>
			  </ScrollViewer>
			</DockPanel>
		  </Border>
		</Popup>
	  </Grid>
	</Border>
	<Border DockPanel.Dock="Bottom" Background="{DynamicResource BarFace}" Padding="10,6">
	  <Border.Effect>
		<DropShadowEffect Color="#000000" BlurRadius="6" ShadowDepth="1" Opacity="0.22" Direction="90"/>
	  </Border.Effect>
	  <DockPanel>
		<TextBlock x:Name="lblFooter" DockPanel.Dock="Right" VerticalAlignment="Center" Foreground="{DynamicResource Theme.Muted}" FontSize="11"/>
		<StackPanel Orientation="Horizontal" VerticalAlignment="Center">
		  <Path Style="{StaticResource Ico}" Data="{StaticResource GeoDownload}" Margin="0,0,5,0"/>
		  <TextBlock x:Name="lblDownTotal" Text="0 B/s" VerticalAlignment="Center" Foreground="{DynamicResource Theme.Ico}" Margin="0,0,14,0"/>
		  <Path Style="{StaticResource Ico}" Data="{StaticResource GeoUpload}" Margin="0,0,5,0"/>
		  <TextBlock x:Name="lblUpTotal" Text="0 B/s" VerticalAlignment="Center" Foreground="{DynamicResource Theme.Ico}" Margin="0,0,14,0"/>
		  <TextBlock x:Name="lblTotals" VerticalAlignment="Center" Foreground="{DynamicResource Theme.Ico}" Text="Torrents: 0"/>
		</StackPanel>
	  </DockPanel>
	</Border>
	<Grid x:Name="grdBody" Background="{DynamicResource Theme.WindowBg}">
	  <Grid.ColumnDefinitions>
		<ColumnDefinition x:Name="colFilter" Width="150"/>
		<ColumnDefinition Width="18"/>
		<ColumnDefinition Width="*"/>
	  </Grid.ColumnDefinitions>
	  <ListBox x:Name="lstFilter" Background="{DynamicResource Theme.ListBg}" Foreground="{DynamicResource Theme.Text}" BorderThickness="0" BorderBrush="{DynamicResource Theme.Border}">
		<ListBoxItem Tag="All" IsSelected="True">
		  <StackPanel Orientation="Horizontal">
			<Path Style="{StaticResource IcoFilter}" Data="{StaticResource GeoCheckMulti}" Margin="0,0,8,0"/>
			<TextBlock Text="All" VerticalAlignment="Center"/>
		  </StackPanel>
		</ListBoxItem>
		<ListBoxItem Tag="Downloading">
		  <StackPanel Orientation="Horizontal">
			<Path Style="{StaticResource IcoFilter}" Data="{StaticResource GeoDownload}" Margin="0,0,8,0"/>
			<TextBlock Text="Downloading" VerticalAlignment="Center"/>
		  </StackPanel>
		</ListBoxItem>
		<ListBoxItem Tag="Seeding">
		  <StackPanel Orientation="Horizontal">
			<Path Style="{StaticResource IcoFilter}" Data="{StaticResource GeoUpload}" Margin="0,0,8,0"/>
			<TextBlock Text="Seeding" VerticalAlignment="Center"/>
		  </StackPanel>
		</ListBoxItem>
		<ListBoxItem Tag="Completed">
		  <StackPanel Orientation="Horizontal">
			<Path Style="{StaticResource IcoFilter}" Data="{StaticResource GeoCheck}" Margin="0,0,8,0"/>
			<TextBlock Text="Completed" VerticalAlignment="Center"/>
		  </StackPanel>
		</ListBoxItem>
		<ListBoxItem Tag="Paused">
		  <StackPanel Orientation="Horizontal">
			<Path Style="{StaticResource IcoFilter}" Data="{StaticResource GeoPause}" Margin="0,0,8,0"/>
			<TextBlock Text="Paused" VerticalAlignment="Center"/>
		  </StackPanel>
		</ListBoxItem>
		<ListBoxItem Tag="Checking">
		  <StackPanel Orientation="Horizontal">
			<Path Style="{StaticResource IcoFilter}" Data="{StaticResource GeoQuestion}" Margin="0,0,8,0"/>
			<TextBlock Text="Checking" VerticalAlignment="Center"/>
		  </StackPanel>
		</ListBoxItem>
	  </ListBox>
	  <Button x:Name="btnFilterFold" Grid.Column="1" Style="{StaticResource CaptionBtn}" Width="18"
			  ToolTip="Hide filters" Background="{DynamicResource Theme.ListBg}">
		<Path x:Name="icoFilterFold" Style="{StaticResource IcoFilter}" Width="12" Height="12"
			  Data="{StaticResource GeoChevronLeft}"/>
	  </Button>
	  <Grid Grid.Column="2" Background="{DynamicResource Theme.WindowBg}">
		<Grid.RowDefinitions>
		  <RowDefinition Height="*"/>
		  <RowDefinition Height="3"/>
		  <RowDefinition Height="210"/>
		</Grid.RowDefinitions>
		<ListView x:Name="lvTorrents" Style="{StaticResource PtListView}" Background="{DynamicResource Theme.WindowBg}" Foreground="{DynamicResource Theme.Text}" BorderThickness="0"
				  SelectionMode="Extended" Focusable="True"
				  VirtualizingStackPanel.IsVirtualizing="True"
				  VirtualizingStackPanel.VirtualizationMode="Recycling">
		  <ListView.ContextMenu>
			<ContextMenu x:Name="ctxTorrents">
			  <MenuItem x:Name="miCtxPlayPause" Header="Pause">
				<MenuItem.Icon>
				  <Path x:Name="icoCtxPlayPause" Style="{StaticResource IcoFilter}" Width="14" Height="14"
						Data="{StaticResource GeoPause}"/>
				</MenuItem.Icon>
			  </MenuItem>
			  <MenuItem x:Name="miCtxStop" Header="Stop">
				<MenuItem.Icon>
				  <Path Style="{StaticResource IcoFilter}" Width="14" Height="14" Data="{StaticResource GeoStop}"/>
				</MenuItem.Icon>
			  </MenuItem>
			  <Separator x:Name="miCtxSep"/>
			  <MenuItem x:Name="miCtxRemove" Header="Remove">
				<MenuItem.Icon>
				  <Path Style="{StaticResource IcoFilter}" Width="14" Height="14" Data="{StaticResource GeoMinus}"/>
				</MenuItem.Icon>
			  </MenuItem>
			</ContextMenu>
		  </ListView.ContextMenu>
		  <ListView.View>
			<GridView>
			  <GridViewColumn Header="Name" Width="220" DisplayMemberBinding="{Binding Name}"/>
			  <GridViewColumn Header="Size" Width="80" DisplayMemberBinding="{Binding SizeText}"/>
			  <GridViewColumn Header="Progress" Width="140">
				<GridViewColumn.CellTemplate>
				  <DataTemplate>
					<Grid Width="120" Height="18">
					  <ProgressBar Minimum="0" Maximum="100" Value="{Binding Progress}" Height="16"/>
					  <TextBlock Text="{Binding ProgressText}" HorizontalAlignment="Center" VerticalAlignment="Center" FontSize="11"
								 Foreground="{DynamicResource Theme.Text}" FontWeight="SemiBold"/>
					</Grid>
				  </DataTemplate>
				</GridViewColumn.CellTemplate>
			  </GridViewColumn>
			  <GridViewColumn Header="Status" Width="88" DisplayMemberBinding="{Binding Status}"/>
			  <GridViewColumn Header="Seeds" Width="70" DisplayMemberBinding="{Binding SeedsText}"/>
			  <GridViewColumn Header="Peers" Width="70" DisplayMemberBinding="{Binding PeersText}"/>
			  <GridViewColumn Width="78" DisplayMemberBinding="{Binding DownText}">
				<GridViewColumn.Header>
				  <StackPanel Orientation="Horizontal">
					<Path Style="{StaticResource Ico}" Width="12" Height="12" Margin="0,0,4,0" Data="{StaticResource GeoDownload}"/>
					<TextBlock Text="Down" VerticalAlignment="Center" Foreground="{DynamicResource Theme.Muted}"/>
				  </StackPanel>
				</GridViewColumn.Header>
			  </GridViewColumn>
			  <GridViewColumn Width="78" DisplayMemberBinding="{Binding UpText}">
				<GridViewColumn.Header>
				  <StackPanel Orientation="Horizontal">
					<Path Style="{StaticResource Ico}" Width="12" Height="12" Margin="0,0,4,0" Data="{StaticResource GeoUpload}"/>
					<TextBlock Text="Up" VerticalAlignment="Center" Foreground="{DynamicResource Theme.Muted}"/>
				  </StackPanel>
				</GridViewColumn.Header>
			  </GridViewColumn>
			  <GridViewColumn Width="72" DisplayMemberBinding="{Binding Eta}">
				<GridViewColumn.Header>
				  <StackPanel Orientation="Horizontal">
					<Path Style="{StaticResource Ico}" Width="12" Height="12" Margin="0,0,4,0" Data="{StaticResource GeoClock}"/>
					<TextBlock Text="ETA" VerticalAlignment="Center" Foreground="{DynamicResource Theme.Muted}"/>
				  </StackPanel>
				</GridViewColumn.Header>
			  </GridViewColumn>
			  <GridViewColumn Header="Ratio" Width="56" DisplayMemberBinding="{Binding RatioText}"/>
			  <GridViewColumn Header="Avail." Width="52" DisplayMemberBinding="{Binding AvailText}"/>
			  <GridViewColumn Header="Remaining" Width="80" DisplayMemberBinding="{Binding RemainingText}"/>
			  <GridViewColumn Header="Downloaded" Width="88" DisplayMemberBinding="{Binding DownTotalText}"/>
			  <GridViewColumn Header="Uploaded" Width="88" DisplayMemberBinding="{Binding UpTotalText}"/>
			</GridView>
		  </ListView.View>
		</ListView>
		<GridSplitter Grid.Row="1" Height="3" HorizontalAlignment="Stretch"/>
		<TabControl x:Name="tabDetails" Grid.Row="2" Background="{DynamicResource Theme.WindowBg}" BorderThickness="0">
		  <TabItem Header="General">
			<ScrollViewer x:Name="scrGeneral" VerticalScrollBarVisibility="Auto" Background="{DynamicResource Theme.WindowBg}"
						  Visibility="Collapsed">
			  <StackPanel x:Name="pnlGeneral" Background="{DynamicResource Theme.RowEven}">
				<Border Style="{StaticResource InfoRowEven}">
				  <TextBlock x:Name="lblName" Text="Name: -"/>
				</Border>
				<Border Style="{StaticResource InfoRowOdd}">
				  <TextBlock x:Name="lblSavePath" Text="Save path: -" TextTrimming="CharacterEllipsis"/>
				</Border>
				<Border Style="{StaticResource InfoRowEven}">
				  <TextBlock x:Name="lblHash" Text="Hash: -" FontFamily="Consolas" FontSize="12" Foreground="{DynamicResource Theme.Muted}" TextWrapping="Wrap"/>
				</Border>
				<Border Style="{StaticResource InfoRowOdd}">
				  <TextBlock x:Name="lblComment" Text="Comment: -" TextWrapping="Wrap"/>
				</Border>
				<Border Style="{StaticResource InfoRowEven}">
				  <TextBlock x:Name="lblCreated" Text="Created by: -" Foreground="{DynamicResource Theme.Muted}"/>
				</Border>
				<Border Style="{StaticResource InfoRowOdd}">
				  <TextBlock x:Name="lblState" Text="State: Idle"/>
				</Border>
				<Border Style="{StaticResource InfoRowEven}">
				  <TextBlock x:Name="lblProgress" Text="Progress: 0%"/>
				</Border>
				<Border Style="{StaticResource InfoRowOdd}">
				  <TextBlock x:Name="lblPieces" Text="Pieces: 0 / 0"/>
				</Border>
				<Border Style="{StaticResource InfoRowEven}">
				  <TextBlock x:Name="lblPeers" Text="Peers: 0 / 0"/>
				</Border>
				<Border Style="{StaticResource InfoRowOdd}">
				  <TextBlock x:Name="lblRatio" Text="Ratio: --    Downloaded 0 B    Uploaded 0 B"/>
				</Border>
				<Border Style="{StaticResource InfoRowEven}">
				  <TextBlock x:Name="lblAvail" Text="Availability: --    Remaining --"/>
				</Border>
				<Border Style="{StaticResource InfoRowOdd}">
				  <TextBlock x:Name="lblSpeed" Text="Down 0 B/s	  Up 0 B/s	 ETA --"/>
				</Border>
			  </StackPanel>
			</ScrollViewer>
		  </TabItem>
		  <TabItem Header="Files">
			<ListView x:Name="lstFiles" Style="{StaticResource PtListView}" FontFamily="Consolas" FontSize="12"
					  BorderThickness="0" Background="{DynamicResource Theme.RowEven}"
					  AlternationCount="2" ItemContainerStyle="{StaticResource PtStripeListViewItem}"
					  SelectionMode="Single">
			  <ListView.View>
				<GridView>
				  <GridViewColumn Header="Name" Width="420" DisplayMemberBinding="{Binding Name}"/>
				  <GridViewColumn Header="Progress" Width="150">
					<GridViewColumn.CellTemplate>
					  <DataTemplate>
						<Grid Width="130" Height="18">
						  <ProgressBar Minimum="0" Maximum="100" Value="{Binding Progress}" Height="16"/>
						  <TextBlock Text="{Binding ProgressText}" HorizontalAlignment="Center" VerticalAlignment="Center" FontSize="11"
									 Foreground="{DynamicResource Theme.Text}" FontWeight="SemiBold"/>
						</Grid>
					  </DataTemplate>
					</GridViewColumn.CellTemplate>
				  </GridViewColumn>
				  <GridViewColumn Header="Size" Width="110">
					<GridViewColumn.CellTemplate>
					  <DataTemplate>
						<TextBlock Text="{Binding SizeText}" HorizontalAlignment="Right" Margin="0,0,8,0"/>
					  </DataTemplate>
					</GridViewColumn.CellTemplate>
				  </GridViewColumn>
				</GridView>
			  </ListView.View>
			</ListView>
		  </TabItem>
		  <TabItem Header="Trackers">
			<ListBox x:Name="lstTrackers" FontFamily="Consolas" FontSize="12" BorderThickness="0"
					 Background="{DynamicResource Theme.RowEven}" AlternationCount="2"
					 ItemContainerStyle="{StaticResource PtStripeListBoxItem}"/>
		  </TabItem>
		  <TabItem Header="Log">
			<TextBox x:Name="txtLog" IsReadOnly="True" TextWrapping="Wrap"
					 VerticalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="12"
					 Background="{DynamicResource Theme.FillDeep}" Foreground="{DynamicResource Theme.Ico}" BorderThickness="0" Padding="8"/>
		  </TabItem>
		</TabControl>
		<Popup x:Name="popMagnet" Placement="Center" StaysOpen="False" AllowsTransparency="True">
		  <Border Background="{DynamicResource Theme.WindowBg}" BorderBrush="{DynamicResource Theme.Border}"
				  BorderThickness="1" Width="480" CornerRadius="2">
			<Border.Effect>
			  <DropShadowEffect Color="#041018" BlurRadius="16" ShadowDepth="3" Opacity="0.45" Direction="270"/>
			</Border.Effect>
			<DockPanel>
			  <Border DockPanel.Dock="Top" Background="{DynamicResource HdrFace}" Padding="12,8">
				<StackPanel Orientation="Horizontal">
				  <Path Style="{StaticResource Ico}" Width="16" Height="16" Margin="0,0,8,0" Data="{StaticResource GeoMagnet}"/>
				  <TextBlock Text="Add magnet link" FontWeight="SemiBold" VerticalAlignment="Center"/>
				</StackPanel>
			  </Border>
			  <StackPanel Margin="16,12">
				<TextBox x:Name="txtMagnet" Height="52" TextWrapping="Wrap" AcceptsReturn="False"/>
				<StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
				  <Button x:Name="btnMagnetOk" Style="{StaticResource DlgBtn}" Margin="0,0,8,0" MinWidth="80">
					<StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
					  <Path Style="{StaticResource IcoOnBtn}" Data="{StaticResource GeoCheck}"/>
					  <TextBlock Text="OK" VerticalAlignment="Center"/>
					</StackPanel>
				  </Button>
				  <Button x:Name="btnMagnetCancel" Style="{StaticResource DlgBtn}" MinWidth="80">
					<StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
					  <Path Style="{StaticResource IcoOnBtn}" Data="{StaticResource GeoMinus}"/>
					  <TextBlock Text="Cancel" VerticalAlignment="Center"/>
					</StackPanel>
				  </Button>
				</StackPanel>
			  </StackPanel>
			</DockPanel>
		  </Border>
		</Popup>
	  </Grid>
	</Grid>
  </DockPanel>
</Window>
'@

	$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
	$window = [Windows.Markup.XamlReader]::Load($reader)

	$ui = @{}
	foreach ($n in @(
			'hdrBar','imgPlanet','txtSave','txtSaveFlyout','btnBrowseDir','chkDht','chkEncrypt','chkUtp','chkSeq','chkSeed','chkCloseToTray',
			'chkVpnRequire','btnVpnImport','btnVpnConnect','btnVpnStop','lblVpnStatus',
			'txtPort','txtPeers','cmbTheme','btnSaveOptions','btnAddFile','btnAddMagnet','btnPlayPause','icoPlayPause','txtPlayPause','btnStop','btnRemove',
			'scrGeneral','pnlGeneral','lblName','lblSavePath','lblHash','lblComment','lblCreated','lblState','lblProgress','lblPieces','lblPeers','lblRatio','lblAvail','lblSpeed',
			'txtLog','lstFiles','lstTrackers','btnRegister','btnRegisterTorrent',
			'btnUnregister','lblAssoc','lblFooter','lblTotals','lblDownTotal','lblUpTotal',
			'btnWinMin','btnWinMax','btnWinClose','pathWinMax','pathWinClose','btnOptions','popOptions',
			'lvTorrents','lstFilter','colFilter','btnFilterFold','icoFilterFold','popMagnet','txtMagnet','btnMagnetOk','btnMagnetCancel',
			'ctxTorrents','miCtxPlayPause','icoCtxPlayPause','miCtxStop','miCtxRemove','miCtxSep'
		)) {
		$ui[$n] = $window.FindName($n)
	}
	$script:PtGeoPause = $window.TryFindResource('GeoPause')
	$script:PtGeoPlay = $window.TryFindResource('GeoPlay')
	$script:PtGeoChevronLeft = $window.TryFindResource('GeoChevronLeft')
	$script:PtGeoChevronRight = $window.TryFindResource('GeoChevronRight')
	$script:PtFilterCollapsed = $false

	$chrome = New-Object System.Windows.Shell.WindowChrome
	$chrome.CaptionHeight = 0
	$chrome.ResizeBorderThickness = New-Object System.Windows.Thickness 6
	$chrome.GlassFrameThickness = New-Object System.Windows.Thickness 0
	$chrome.CornerRadius = New-Object System.Windows.CornerRadius 0
	$chrome.UseAeroCaptionButtons = $false
	[System.Windows.Shell.WindowChrome]::SetWindowChrome($window, $chrome)
	foreach ($b in @($ui.btnWinMin, $ui.btnWinMax, $ui.btnWinClose)) {
		[System.Windows.Shell.WindowChrome]::SetIsHitTestVisibleInChrome($b, $true)
	}
	$ui.popOptions.PlacementTarget = $ui.btnOptions
	$ui.popOptions.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
	$ui.popOptions.HorizontalOffset = -308
	try { [PowerTorrent.WindowMaximizeFix]::Attach($window) } catch { }

	$wmploc = '%SystemRoot%\System32\wmploc.dll'
	$script:PtPlanetIdle = Get-NativeIconBitmap -File $wmploc -Index 139 -Large
	$script:PtPlanetFrames = @()
	foreach ($idx in 137..151) {
		$fr = Get-NativeIconBitmap -File $wmploc -Index $idx -Large
		if ($fr) { $script:PtPlanetFrames += ,$fr }
	}
	if (-not $script:PtPlanetIdle -and $script:PtPlanetFrames.Count -ge 3) {
		$script:PtPlanetIdle = $script:PtPlanetFrames[2]
	}
	if ($script:PtPlanetIdle) {
		$ui.imgPlanet.Source = $script:PtPlanetIdle
		$window.Icon = $script:PtPlanetIdle
	}
	$script:PtPlanetIndex = 0
	$script:PtPlanetConnected = $false
	$script:PtTrayIdle = $null
	try { $script:PtTrayIdle = Get-NativeWinIcon -File $wmploc -Index 139 } catch { }
	if (-not $script:PtTrayIdle) {
		try { $script:PtTrayIdle = [System.Drawing.SystemIcons]::Application } catch { }
	}

	$script:PtGeomMax = [System.Windows.Media.Geometry]::Parse('M0.5,0.5 H9.5 V9.5 H0.5 Z')
	$script:PtGeomRestore = [System.Windows.Media.Geometry]::Parse('M2.5,0.5 H9.5 V7.5 H8.5 V1.5 H2.5 Z M0.5,2.5 H7.5 V9.5 H0.5 Z')

	$script:PtJobs = New-Object System.Collections.Generic.List[object]
	$script:PtRows = New-Object 'System.Collections.ObjectModel.ObservableCollection[PowerTorrent.TorrentRow]'
	$ui.lvTorrents.ItemsSource = $script:PtRows
	try {
		$script:PtView = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:PtRows)
		if ($script:PtView) { $script:PtView.Filter = [PowerTorrent.TorrentRowFilter]::GetPredicate() }
	} catch { }
	$script:PtLogSeen = @{}
	$script:PtDetailId = ''
	$script:PtWindow = $window
	$script:PtNextPort = [int]$Port
	if ($script:PtNextPort -le 0) { $script:PtNextPort = 6881 }

	if ($InitialSave) { $ui.txtSave.Text = $InitialSave }
	else { $ui.txtSave.Text = Get-DefaultSavePath }
	if ($ui.txtSaveFlyout) { $ui.txtSaveFlyout.Text = $ui.txtSave.Text }
	$ui.txtPort.Text = [string]$Port
	$ui.txtPeers.Text = [string]$MaxPeers
	$ui.chkDht.IsChecked = -not [bool]$NoDht
	$ui.chkEncrypt.IsChecked = -not [bool]$NoEncrypt
	$ui.chkUtp.IsChecked = -not [bool]$NoUtp
	$ui.chkSeq.IsChecked = [bool]$Sequential
	$ui.chkSeed.IsChecked = -not [bool]$NoSeed
	if ($null -eq $script:PtCloseToTray) { $script:PtCloseToTray = $false }
	$ui.chkCloseToTray.IsChecked = [bool]$script:PtCloseToTray
	if ($null -eq $script:PtVpnRequire) { $script:PtVpnRequire = $true }
	if ($null -eq $script:PtVpnAuto) { $script:PtVpnAuto = $true }
	if ($ui.chkVpnRequire) { $ui.chkVpnRequire.IsChecked = [bool]$script:PtVpnRequire }
	if (-not $script:PtTheme) { $script:PtTheme = 'Ice' }
	foreach ($tn in @(Get-PtThemeNames)) { [void]$ui.cmbTheme.Items.Add($tn) }
	$themePick = 'Ice'
	foreach ($it in $ui.cmbTheme.Items) {
		if ([string]$it -eq $script:PtTheme) { $themePick = [string]$it; break }
	}
	$script:PtTheme = $themePick
	$ui.cmbTheme.SelectedItem = $themePick
	try { Apply-PtTheme $window $themePick } catch { }

	function Show-PtMessage {
		param(
			[string]$Message,
			[string]$Title = 'PowerTorrent',
			[ValidateSet('OK','YesNo')]
			[string]$Buttons = 'OK',
			[string]$CheckLabel = '',
			[bool]$CheckDefault = $false
		)
		$yesNo = ($Buttons -eq 'YesNo')
		$dlgXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
		xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
		Title="$Title" SizeToContent="WidthAndHeight"
		WindowStartupLocation="CenterOwner" WindowStyle="None"
		ResizeMode="NoResize" Background="{DynamicResource Theme.WindowBg}"
		Foreground="{DynamicResource Theme.Text}"
		FontFamily="Segoe UI" FontSize="13"
		BorderBrush="{DynamicResource Theme.Border}" BorderThickness="1"
		ShowInTaskbar="False">
  <Window.Resources>
	<SolidColorBrush x:Key="Theme.WindowBg" Color="#141A1E"/>
	<SolidColorBrush x:Key="Theme.Text" Color="#E8F4F8"/>
	<SolidColorBrush x:Key="Theme.Muted" Color="#A8C4CC"/>
	<SolidColorBrush x:Key="Theme.Accent" Color="#6BB3C4"/>
	<SolidColorBrush x:Key="Theme.AccentHi" Color="#8FD4E3"/>
	<SolidColorBrush x:Key="Theme.AccentDeep" Color="#1E4A5C"/>
	<SolidColorBrush x:Key="Theme.Fill" Color="#1A2228"/>
	<SolidColorBrush x:Key="Theme.FillDeep" Color="#10161A"/>
	<SolidColorBrush x:Key="Theme.Border" Color="#3D5A66"/>
	<SolidColorBrush x:Key="Theme.BorderHi" Color="#8FD4E3"/>
	<SolidColorBrush x:Key="Theme.CaptionHover" Color="#2A4450"/>
	<SolidColorBrush x:Key="Theme.CaptionPress" Color="#1A3A48"/>
	<SolidColorBrush x:Key="Theme.Disabled" Color="#6A7A80"/>
	<SolidColorBrush x:Key="Theme.CheckOn" Color="#1E4A5C"/>
	<SolidColorBrush x:Key="Theme.CheckMark" Color="#E8F4F8"/>
	<StreamGeometry x:Key="GeoCheck">M21,7L9,19L3.5,13.5L4.91,12.09L9,16.17L19.59,5.59L21,7Z</StreamGeometry>
	<LinearGradientBrush x:Key="HdrFace" StartPoint="0,0" EndPoint="0,1">
	  <GradientStop Color="#1A242C" Offset="0"/>
	  <GradientStop Color="#10161A" Offset="1"/>
	</LinearGradientBrush>
	<LinearGradientBrush x:Key="BtnFace" StartPoint="0,0" EndPoint="0,1">
	  <GradientStop Color="#334650" Offset="0"/>
	  <GradientStop Color="#1E2C34" Offset="1"/>
	</LinearGradientBrush>
	<LinearGradientBrush x:Key="BtnHover" StartPoint="0,0" EndPoint="0,1">
	  <GradientStop Color="#3E5C68" Offset="0"/>
	  <GradientStop Color="#2A4450" Offset="1"/>
	</LinearGradientBrush>
	<LinearGradientBrush x:Key="BtnPress" StartPoint="0,0" EndPoint="0,1">
	  <GradientStop Color="#1A3A48" Offset="0"/>
	  <GradientStop Color="#122830" Offset="1"/>
	</LinearGradientBrush>
	<Style TargetType="TextBlock">
	  <Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
	</Style>
	<Style TargetType="CheckBox">
	  <Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="CheckBox">
			<StackPanel Orientation="Horizontal">
			  <Border x:Name="box" Width="16" Height="16" Background="{DynamicResource Theme.Fill}"
					  BorderBrush="{DynamicResource Theme.Border}" BorderThickness="1" CornerRadius="2"
					  Margin="0,0,8,0" VerticalAlignment="Center">
				<Path x:Name="check" Data="{StaticResource GeoCheck}" Fill="{DynamicResource Theme.CheckMark}"
					  Stretch="Uniform" Margin="2" Visibility="Collapsed"/>
			  </Border>
			  <ContentPresenter VerticalAlignment="Center" RecognizesAccessKey="True"/>
			</StackPanel>
			<ControlTemplate.Triggers>
			  <Trigger Property="IsChecked" Value="True">
				<Setter TargetName="check" Property="Visibility" Value="Visible"/>
				<Setter TargetName="box" Property="Background" Value="{DynamicResource Theme.CheckOn}"/>
				<Setter TargetName="box" Property="BorderBrush" Value="{DynamicResource Theme.Accent}"/>
			  </Trigger>
			  <Trigger Property="IsMouseOver" Value="True">
				<Setter TargetName="box" Property="BorderBrush" Value="{DynamicResource Theme.AccentHi}"/>
			  </Trigger>
			</ControlTemplate.Triggers>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
	<Style TargetType="Button">
	  <Setter Property="Background" Value="{DynamicResource BtnFace}"/>
	  <Setter Property="Foreground" Value="{DynamicResource Theme.Text}"/>
	  <Setter Property="BorderBrush" Value="{DynamicResource Theme.Border}"/>
	  <Setter Property="BorderThickness" Value="1"/>
	  <Setter Property="Padding" Value="10,4"/>
	  <Setter Property="OverridesDefaultStyle" Value="True"/>
	  <Setter Property="Template">
		<Setter.Value>
		  <ControlTemplate TargetType="Button">
			<Border x:Name="bd" Background="{TemplateBinding Background}"
					BorderBrush="{TemplateBinding BorderBrush}"
					BorderThickness="{TemplateBinding BorderThickness}"
					Padding="{TemplateBinding Padding}" CornerRadius="3">
			  <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
			</Border>
			<ControlTemplate.Triggers>
			  <Trigger Property="IsMouseOver" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource BtnHover}"/>
				<Setter TargetName="bd" Property="BorderBrush" Value="{DynamicResource Theme.AccentHi}"/>
			  </Trigger>
			  <Trigger Property="IsPressed" Value="True">
				<Setter TargetName="bd" Property="Background" Value="{DynamicResource BtnPress}"/>
			  </Trigger>
			</ControlTemplate.Triggers>
		  </ControlTemplate>
		</Setter.Value>
	  </Setter>
	</Style>
  </Window.Resources>
  <DockPanel>
	<Border DockPanel.Dock="Top" Background="{DynamicResource HdrFace}" Padding="12,8">
	  <TextBlock x:Name="lblTitle" FontWeight="SemiBold"/>
	</Border>
	<StackPanel Margin="18,14" Width="380">
	  <TextBlock x:Name="lblMsg" TextWrapping="Wrap" Margin="0,0,0,16"/>
	  <CheckBox x:Name="chkExtra" Margin="0,0,0,14" Visibility="Collapsed"/>
	  <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
		<Button x:Name="btnA" MinWidth="84" Height="28" Margin="0,0,8,0" IsDefault="True"/>
		<Button x:Name="btnB" MinWidth="84" Height="28" IsCancel="True"/>
	  </StackPanel>
	</StackPanel>
  </DockPanel>
</Window>
"@
		$w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$dlgXaml)))
		try {
			$th = $script:PtTheme
			if ([string]::IsNullOrWhiteSpace($th)) { $th = 'Ice' }
			Apply-PtTheme $w $th
		} catch { }
		try { $w.Owner = $window } catch { }
		$w.FindName('lblTitle').Text = $Title
		$w.FindName('lblMsg').Text = $Message
		$chk = $w.FindName('chkExtra')
		$script:PtDlgChecked = $false
		if ($chk -and -not [string]::IsNullOrWhiteSpace($CheckLabel)) {
			$chk.Content = $CheckLabel
			$chk.IsChecked = [bool]$CheckDefault
			$chk.Visibility = [System.Windows.Visibility]::Visible
		}
		$btnA = $w.FindName('btnA')
		$btnB = $w.FindName('btnB')
		$script:PtDlgResult = 'No'
		$script:PtDlgWin = $w
		if ($yesNo) {
			$btnA.Content = 'Yes'
			$btnB.Content = 'No'
			$btnA.add_Click({ $script:PtDlgResult = 'Yes'; try { $script:PtDlgWin.DialogResult = $true } catch { $script:PtDlgWin.Close() } })
			$btnB.add_Click({ $script:PtDlgResult = 'No'; try { $script:PtDlgWin.DialogResult = $false } catch { $script:PtDlgWin.Close() } })
		} else {
			$btnA.Content = 'OK'
			$btnB.Visibility = [System.Windows.Visibility]::Collapsed
			$btnA.add_Click({ $script:PtDlgResult = 'OK'; try { $script:PtDlgWin.DialogResult = $true } catch { $script:PtDlgWin.Close() } })
		}
		[void]$w.ShowDialog()
		if ($chk) { $script:PtDlgChecked = [bool]$chk.IsChecked }
		return $script:PtDlgResult
	}

	function Get-PtUiOptionMap {
		$portVal = Get-PtInt -Text $ui.txtPort.Text -Fallback 6881
		$peerVal = Get-PtInt -Text $ui.txtPeers.Text -Fallback 80
		$th = [string]$ui.cmbTheme.SelectedItem
		if ([string]::IsNullOrWhiteSpace($th)) { $th = 'Ice' }
		$save = [string]$ui.txtSave.Text
		if ($ui.txtSaveFlyout -and -not [string]::IsNullOrWhiteSpace($ui.txtSaveFlyout.Text)) {
			$save = [string]$ui.txtSaveFlyout.Text
			$ui.txtSave.Text = $save
		}
		@{
			Theme	   = $th
			Dht		   = Get-PtBoolText ([bool]$ui.chkDht.IsChecked)
			Encrypt	   = Get-PtBoolText ([bool]$ui.chkEncrypt.IsChecked)
			Utp		   = Get-PtBoolText ([bool]$ui.chkUtp.IsChecked)
			Sequential = Get-PtBoolText ([bool]$ui.chkSeq.IsChecked)
			Seed	   = Get-PtBoolText ([bool]$ui.chkSeed.IsChecked)
			CloseToTray = Get-PtBoolText ([bool]$ui.chkCloseToTray.IsChecked)
			VpnRequire = Get-PtBoolText ([bool]$ui.chkVpnRequire.IsChecked)
			VpnAuto	   = Get-PtBoolText ([bool]$script:PtVpnAuto)
			Port	   = [string]$portVal
			MaxPeers   = [string]$peerVal
			SavePath   = $save
		}
	}
	function Get-PtCompareOptionMap {
		$d = Get-PtDefaultOptions
		$ini = Read-PtIni
		foreach ($k in @('Theme','Dht','Encrypt','Utp','Sequential','Seed','Port','MaxPeers','SavePath','CloseToTray','VpnRequire','VpnAuto')) {
			if ($ini.ContainsKey($k) -and $null -ne $ini[$k] -and [string]$ini[$k] -ne '') { $d[$k] = [string]$ini[$k] }
		}
		return $d
	}
	function Update-SaveOptionsButton {
		if ($ui.btnSaveOptions) {
			$ui.btnSaveOptions.Visibility = [System.Windows.Visibility]::Visible
		}
	}

	function Sync-LiveOptions {
		try {
			$portVal = Get-PtInt -Text $ui.txtPort.Text -Fallback 6881
			$peerVal = Get-PtInt -Text $ui.txtPeers.Text -Fallback 80
			$n = 0
			if ($script:PtJobs) { $n = $script:PtJobs.Count }
			for ($i = 0; $i -lt $n; $i++) {
				$job = $script:PtJobs[$i]
				$cfg = $job.Engine.Settings
				$cfg.EnableDht = [bool]$ui.chkDht.IsChecked
				$cfg.EnableEncrypt = [bool]$ui.chkEncrypt.IsChecked
				$cfg.EnableUtp = [bool]$ui.chkUtp.IsChecked
				$cfg.Sequential = [bool]$ui.chkSeq.IsChecked
				$cfg.SeedAfterComplete = [bool]$ui.chkSeed.IsChecked
				$cfg.MaxPeers = $peerVal
				$script:PtCloseToTray = [bool]$ui.chkCloseToTray.IsChecked
				try { $job.Engine.ApplyLiveSettings() } catch { }
			}
			try { Update-SaveOptionsButton } catch { }
		} catch { }
	}
	$optSync = { try { Sync-LiveOptions } catch { } }
	foreach ($c in @($ui.chkDht, $ui.chkEncrypt, $ui.chkUtp, $ui.chkSeq, $ui.chkSeed, $ui.chkCloseToTray)) {
		$c.add_Click($optSync)
	}
	$ui.txtPort.add_LostFocus($optSync)
	$ui.txtPeers.add_LostFocus($optSync)
	$ui.txtSave.add_LostFocus({ Update-SaveOptionsButton })
	$ui.cmbTheme.add_SelectionChanged({
		$th = [string]$ui.cmbTheme.SelectedItem
		if ($th) {
			$script:PtTheme = $th
			try { Apply-PtTheme $window $th } catch { }
		}
		try { Update-SaveOptionsButton } catch { }
	})
	$ui.btnSaveOptions.add_Click({
		try {
			Merge-PtIni (Get-PtUiOptionMap)
			Update-SaveOptionsButton
			Add-UiLog 'Options saved'
		} catch {
			Show-PtMessage -Message ([string]$_) | Out-Null
		}
	})
	foreach ($c in @($ui.chkDht, $ui.chkEncrypt, $ui.chkUtp, $ui.chkSeq, $ui.chkSeed, $ui.chkCloseToTray)) {
		$c.add_Click({ try { Update-SaveOptionsButton } catch { } })
	}
	$ui.txtPort.add_LostFocus({ try { Update-SaveOptionsButton } catch { } })
	$ui.txtPeers.add_LostFocus({ try { Update-SaveOptionsButton } catch { } })
	try { Update-SaveOptionsButton } catch { }

	function Update-AssocLabel {
		if (Test-PowerTorrentMagnetAssociation) {
			$ui.lblAssoc.Text = 'magnet: registered for this user'
		} else {
			$ui.lblAssoc.Text = 'magnet: not registered'
		}
	}
	Update-AssocLabel

	function Update-PtVpnUi {
		$st = [string][PowerTorrent.VpnHub]::Status
		$err = [string][PowerTorrent.VpnHub]::LastError
		$has = [bool][PowerTorrent.VpnHub]::HasConfig
		$up = [bool][PowerTorrent.VpnHub]::TunnelOn
		if ($ui.lblVpnStatus) {
			if (-not $has) {
				$ui.lblVpnStatus.Text = 'No config imported.'
			} elseif ($up) {
				$proven = [string][PowerTorrent.VpnHub]::ProvenIp
				if ($proven) {
					$ui.lblVpnStatus.Text = ('Connected. {0}' -f $proven)
				} else {
					$ui.lblVpnStatus.Text = 'Connected.'
				}
			} elseif ($err) {
				$ui.lblVpnStatus.Text = ('{0} - {1}' -f $st, $err)
			} else {
				$ui.lblVpnStatus.Text = $st
			}
		}
		if ($ui.lblFooter) {
			if ($up) {
				$proven = [string][PowerTorrent.VpnHub]::ProvenIp
				if ($proven) { $ui.lblFooter.Text = ('VPN IP: {0}' -f $proven) }
				else { $ui.lblFooter.Text = 'VPN IP:' }
			} elseif ($has) {
				$ui.lblFooter.Text = ('VPN: {0}' -f $st)
			} else { $ui.lblFooter.Text = '' }
		}
		if ($has -and $ui.chkVpnRequire) { $ui.chkVpnRequire.IsChecked = $true }
		if ($ui.btnVpnConnect) { $ui.btnVpnConnect.IsEnabled = $has -and -not $up }
		if ($ui.btnVpnStop) { $ui.btnVpnStop.IsEnabled = $has }
	}

	function Start-PtVpnBackground {
		if (-not [PowerTorrent.VpnHub]::HasConfig) { return }
		try {
			[void][PowerTorrent.VpnHub]::BeginStart()
			Add-UiLog 'VPN connecting'
		} catch {
			Show-PtMessage -Message ([string]$_) | Out-Null
		}
		Update-PtVpnUi
	}

	if ($ui.chkVpnRequire) {
		$ui.chkVpnRequire.add_Click({
			if ([bool][PowerTorrent.VpnHub]::HasConfig) {
				$ui.chkVpnRequire.IsChecked = $true
				$script:PtVpnRequire = $true
			} else {
				$script:PtVpnRequire = [bool]$ui.chkVpnRequire.IsChecked
			}
			[PowerTorrent.VpnHub]::Require = [bool]$script:PtVpnRequire
			try { [PowerTorrent.Session]::RebindListen() } catch { }
			try { Update-PtVpnUi } catch { }
			try { Update-SaveOptionsButton } catch { }
		})
	}
	if ($ui.btnVpnImport) {
		$ui.btnVpnImport.add_Click({
			try {
				$dlg = New-Object System.Windows.Forms.OpenFileDialog
				$dlg.Filter = 'VPN config (*.conf;*.ovpn)|*.conf;*.ovpn|WireGuard (*.conf)|*.conf|OpenVPN (*.ovpn)|*.ovpn|All files (*.*)|*.*'
				$dlg.Title = 'Import VPN config'
				if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
				$text = [System.IO.File]::ReadAllText($dlg.FileName)
				$err = ''
				$ok = [PowerTorrent.VpnHub]::LoadConfig($text, [ref]$err)
				if (-not $ok) {
					Show-PtMessage -Message $err | Out-Null
					Update-PtVpnUi
					return
				}
				[System.IO.File]::WriteAllText((Get-PtVpnConfPath), $text)
				$script:PtVpnRequire = [bool]$ui.chkVpnRequire.IsChecked
				[PowerTorrent.VpnHub]::Require = [bool]$script:PtVpnRequire
				$script:PtVpnAuto = $true
				Add-UiLog 'VPN config imported'
				Update-PtVpnUi
				Start-PtVpnBackground
			} catch {
				Show-PtMessage -Message ([string]$_) | Out-Null
			}
		})
	}
	if ($ui.btnVpnConnect) {
		$ui.btnVpnConnect.add_Click({
			try { Start-PtVpnBackground } catch { Show-PtMessage -Message ([string]$_) | Out-Null }
		})
	}
	if ($ui.btnVpnStop) {
		$ui.btnVpnStop.add_Click({
			try {
				[PowerTorrent.VpnHub]::Stop()
				Add-UiLog 'VPN disconnected'
				Update-PtVpnUi
			} catch { Show-PtMessage -Message ([string]$_) | Out-Null }
		})
	}
	try { Update-PtVpnUi } catch { }

	function Add-UiLog([string]$line) {
		if ([string]::IsNullOrWhiteSpace($line)) { return }
		$ui.txtLog.AppendText($line + [Environment]::NewLine)
		$ui.txtLog.ScrollToEnd()
	}

	function Get-SelectedJob {
		$row = $ui.lvTorrents.SelectedItem
		if (-not $row) { return $null }
		$n = 0
		if ($script:PtJobs) { $n = $script:PtJobs.Count }
		for ($i = 0; $i -lt $n; $i++) {
			$j = $script:PtJobs[$i]
			if ($j.Id -eq $row.Id) { return $j }
		}
		return $null
	}

	function Get-SelectedJobs {
		$ids = @{}
		try {
			foreach ($row in @($ui.lvTorrents.SelectedItems)) {
				if ($row -and $row.Id) { $ids[[string]$row.Id] = $true }
			}
		} catch { }
		$out = New-Object System.Collections.Generic.List[object]
		$n = 0
		if ($script:PtJobs) { $n = $script:PtJobs.Count }
		for ($i = 0; $i -lt $n; $i++) {
			$j = $script:PtJobs[$i]
			if ($ids.ContainsKey([string]$j.Id)) { [void]$out.Add($j) }
		}
		return , $out.ToArray()
	}

	function Get-PtCurrentSavePath {
		$p = [string]$ui.txtSave.Text
		if ($ui.txtSaveFlyout -and -not [string]::IsNullOrWhiteSpace($ui.txtSaveFlyout.Text)) {
			$p = [string]$ui.txtSaveFlyout.Text
			$ui.txtSave.Text = $p
		}
		return $p
	}

	function Add-PtTorrent {
		param([string]$Source)
		$src = $Source.Trim()
		$isMag = $src.ToLowerInvariant().StartsWith('magnet:')
		if (-not $isMag) {
			if (-not (Test-Path -LiteralPath $src)) {
				Show-PtMessage -Message "Torrent file not found:`n$src" | Out-Null
				return
			}
			$src = [System.IO.Path]::GetFullPath($src)
		}
		$jc = 0
		if ($script:PtJobs) { $jc = $script:PtJobs.Count }
		$maxT = [PowerTorrent.Session]::MaxTorrents
		if ($jc -ge $maxT) {
			Show-PtMessage -Message ("Already have {0} torrents (session limit)." -f $maxT) | Out-Null
			return
		}
		for ($ji = 0; $ji -lt $jc; $ji++) {
			if ($script:PtJobs[$ji].Source -eq $src) { return }
		}
		$script:PtNextPort = Get-PtInt -Text $ui.txtPort.Text -Fallback $script:PtNextPort
		$peerVal = Get-PtInt -Text $ui.txtPeers.Text -Fallback 80
		$portVal = $script:PtNextPort
		try {
			$cfg = New-PowerTorrentSettings -Source $src -OutDir (Get-PtCurrentSavePath) -ListenPort $portVal -Peers $peerVal `
				-Dht ([bool]$ui.chkDht.IsChecked) -Encrypt ([bool]$ui.chkEncrypt.IsChecked) -Utp ([bool]$ui.chkUtp.IsChecked) `
				-Seq ([bool]$ui.chkSeq.IsChecked) -Seed ([bool]$ui.chkSeed.IsChecked) -Forced $Peer -Level $LogLevel
			$eng = [PowerTorrent.Engine]::new($cfg)
			$info = $eng.GetInfo()
			$id = [guid]::NewGuid().ToString('N').Substring(0, 8)
			$row = New-Object PowerTorrent.TorrentRow
			$row.Id = $id
			$row.Name = $(if ($info.Name) { $info.Name } else { $src })
			$row.Hash = $info.InfoHashHex
			$row.Apply($eng.GetStatus())
			if ($row.Hash) {
				for ($ji = 0; $ji -lt $jc; $ji++) {
					if ($script:PtJobs[$ji].Row.Hash -eq $row.Hash) { return }
				}
			}
			$job = New-Object psobject -Property @{
				Id = $id
				Engine = $eng
				Row = $row
				Source = $src
				LogSeen = @{}
			}
			$script:PtJobs.Add($job)
			$script:PtRows.Add($row)
			$eng.Start()
			$script:PtPlanetConnected = $true
			$ui.lvTorrents.SelectedItem = $row
			Add-UiLog ('Added {0}' -f $row.Name)
		} catch {
			Show-PtMessage -Message ([string]$_) | Out-Null
		}
	}

	function Stop-AllTorrents {
		foreach ($job in @($script:PtJobs)) {
			try { $job.Engine.Stop() } catch { }
		}
		$script:PtJobs.Clear()
		$script:PtRows.Clear()
		$script:PtPlanetConnected = $false
		if ($script:PtPlanetIdle -and $ui.imgPlanet) { $ui.imgPlanet.Source = $script:PtPlanetIdle }
	}

	function Get-PtFilterName {
		$item = $ui.lstFilter.SelectedItem
		if ($item -is [System.Windows.Controls.ListBoxItem]) {
			if ($null -ne $item.Tag -and [string]$item.Tag -ne '') { return [string]$item.Tag }
			return [string]$item.Content
		}
		return [string]$item
	}

	function Test-PtRowVisible([string]$st) {
		switch (Get-PtFilterName) {
			'Downloading' { return ($st -eq 'Downloading' -or $st -eq 'Metadata' -or $st -eq 'Announcing' -or $st -eq 'VPN') }
			'Seeding' { return ($st -eq 'Seeding') }
			'Completed' { return ($st -eq 'Complete' -or $st -eq 'Seeding') }
			'Paused' { return ($st -eq 'Paused') }
			'Checking' { return ($st -eq 'Hashing') }
			default { return $true }
		}
	}

	function Update-FilterView {
		[PowerTorrent.TorrentRowFilter]::Name = Get-PtFilterName
		if ($script:PtView) { try { $script:PtView.Refresh() } catch { } }
	}

	function Update-UiStatus {
		try {
			$incoming = Read-PtInbox
			if ($incoming) {
				foreach ($line in $incoming) { Add-PtTorrent -Source $line }
			}
			$anyPeers = $false
			$sumDown = [double]0
			$sumUp = [double]0
			$sumDl = [long]0
			$sumUl = [long]0
			$count = $script:PtJobs.Count
			for ($i = 0; $i -lt $count; $i++) {
				$job = $script:PtJobs[$i]
				try { $s = $job.Engine.GetStatus() } catch { continue }
				$job.Row.Apply($s)
				$sumDown += [double]$s.DownBytesPerSec
				$sumUp += [double]$s.UpBytesPerSec
				$sumDl += [long]$s.Downloaded
				$sumUl += [long]$s.Uploaded
				if ($job.Engine.IsRunning -and -not $job.Engine.IsPaused) { $anyPeers = $true }
			}
			$script:PtPlanetConnected = $anyPeers
			$ui.lblDownTotal.Text = ('{0}/s' -f [PowerTorrent.Engine]::Fmt([long]$sumDown))
			$ui.lblUpTotal.Text = ('{0}/s' -f [PowerTorrent.Engine]::Fmt([long]$sumUp))
			$ratioTxt = '--'
			if ($sumDl -gt 0) { $ratioTxt = ('{0:0.000}' -f ($sumUl / [double]$sumDl)) }
			elseif ($sumUl -gt 0) { $ratioTxt = [string][char]0x221E }
			$ui.lblTotals.Text = ('Torrents: {0} / {1}    Ratio: {2}' -f $count, [PowerTorrent.Session]::MaxTorrents, $ratioTxt)
			try { Update-PtVpnUi } catch { }
			Update-TransportButtons
			$job = Get-SelectedJob
			if ($job) {
				if ($ui.scrGeneral) { $ui.scrGeneral.Visibility = [System.Windows.Visibility]::Visible }
				$s = $job.Engine.GetStatus()
				$ui.lblName.Text = ('Name: {0}' -f $(if ($s.Name) { $s.Name } else { '-' }))
				$ui.lblHash.Text = ('Hash: {0}' -f $(if ($s.InfoHashHex) { $s.InfoHashHex } else { '-' }))
				$ui.lblState.Text = ('State: {0}' -f $s.State)
				$ui.lblProgress.Text = ('Progress: {0:0.00}%   {1} / {2}' -f $s.ProgressPercent, [PowerTorrent.Engine]::Fmt([long]$s.Downloaded), [PowerTorrent.Engine]::Fmt([long]$s.TotalSize))
				if ($ui.lblPieces) { $ui.lblPieces.Text = ('Pieces: {0} / {1}' -f $s.PiecesDone, $s.PiecesTotal) }
				$ui.lblPeers.Text = ('Peers: {0} connected / {1} known    Seeds: {2} / {3}    listen {4}' -f $s.PeersConnected, $s.PeersKnown, $s.SeedsConnected, $s.SeedsKnown, $s.ListenPort)
				$ratioSel = '--'
				if ($s.Downloaded -gt 0) { $ratioSel = ('{0:0.000}' -f ($s.Uploaded / [double]$s.Downloaded)) }
				elseif ($s.Uploaded -gt 0) { $ratioSel = [string][char]0x221E }
				if ($ui.lblRatio) {
					$ui.lblRatio.Text = ('Ratio: {0}    Downloaded {1}    Uploaded {2}' -f $ratioSel, [PowerTorrent.Engine]::Fmt([long]$s.Downloaded), [PowerTorrent.Engine]::Fmt([long]$s.Uploaded))
				}
				$rem = $s.TotalSize - $s.Downloaded
				if ($rem -lt 0) { $rem = 0 }
				if ($ui.lblAvail) {
					$av = $(if ($s.Availability -gt 0) { '{0:0.0}' -f $s.Availability } else { '--' })
					$ui.lblAvail.Text = ('Availability: {0}    Remaining {1}' -f $av, [PowerTorrent.Engine]::Fmt([long]$rem))
				}
				$ui.lblSpeed.Text = ('Down {0}/s   Up {1}/s	  ETA {2}' -f [PowerTorrent.Engine]::Fmt([long]$s.DownBytesPerSec), [PowerTorrent.Engine]::Fmt([long]$s.UpBytesPerSec), $s.Eta)
				$jid = '{0}|{1}' -f $job.Id, $s.PiecesTotal
				if ($script:PtDetailId -ne $jid) {
					$script:PtDetailId = $jid
					try {
						$info = $job.Engine.GetInfo()
						if ($ui.lblSavePath) {
							$ui.lblSavePath.Text = ('Save path: {0}' -f $(if ($info.SavePath) { $info.SavePath } else { '-' }))
						}
						if ($ui.lblComment) {
							$c = [string]$info.Comment
							if ([string]::IsNullOrWhiteSpace($c)) { $c = '-' }
							$ui.lblComment.Text = ('Comment: {0}' -f $c)
						}
						if ($ui.lblCreated) {
							$cb = [string]$info.CreatedBy
							if ([string]::IsNullOrWhiteSpace($cb)) { $cb = '-' }
							$ui.lblCreated.Text = ('Created by: {0}    Files: {1}    Piece size: {2}' -f $cb, $info.FileCount, [PowerTorrent.Engine]::Fmt([long]$info.PieceLength))
						}
						if ($ui.lstFiles) {
							$ui.lstFiles.Items.Clear()
							$rows = $null
							try { $rows = $info.FileRows } catch { $rows = $null }
							if ($rows -and $rows.Length -gt 0) {
								foreach ($fr in @($rows)) { [void]$ui.lstFiles.Items.Add($fr) }
							} else {
								$empty = New-Object PowerTorrent.FileRow
								$empty.Name = '(no files yet)'
								$empty.SizeText = ''
								$empty.ProgressText = ''
								[void]$ui.lstFiles.Items.Add($empty)
							}
						}
						if ($ui.lstTrackers) {
							$ui.lstTrackers.Items.Clear()
							if ($info.Trackers -and $info.Trackers.Length -gt 0) {
								foreach ($tr in @($info.Trackers)) { [void]$ui.lstTrackers.Items.Add($tr) }
							} else { [void]$ui.lstTrackers.Items.Add('(no trackers)') }
							if ($info.Webseeds) {
								foreach ($ws in @($info.Webseeds)) {
									[void]$ui.lstTrackers.Items.Add(('webseed  {0}' -f $ws))
								}
							}
						}
					} catch { }
				}
				if ($ui.lstFiles -and $ui.lstFiles.Items.Count -gt 0 -and $ui.lstFiles.Items[0] -is [PowerTorrent.FileRow]) {
					try {
						$nfr = $ui.lstFiles.Items.Count
						$frArr = New-Object 'PowerTorrent.FileRow[]' $nfr
						for ($fi = 0; $fi -lt $nfr; $fi++) { $frArr[$fi] = [PowerTorrent.FileRow]$ui.lstFiles.Items[$fi] }
						$job.Engine.UpdateFileProgress($frArr)
					} catch { }
				}
				$logs = $s.LogLines
				if ($logs) {
					for ($li = 0; $li -lt $logs.Length; $li++) {
						$line = $logs[$li]
						$key = $job.Id + '|' + $line
						if ($line -and -not $script:PtLogSeen.ContainsKey($key)) {
							$script:PtLogSeen[$key] = $true
							Add-UiLog (('[{0}] {1}' -f $job.Row.Name, $line))
						}
					}
				}
			} else {
				$script:PtDetailId = ''
				if ($ui.scrGeneral) { $ui.scrGeneral.Visibility = [System.Windows.Visibility]::Collapsed }
				if ($ui.lstFiles) { $ui.lstFiles.Items.Clear() }
				if ($ui.lstTrackers) { $ui.lstTrackers.Items.Clear() }
			}
		} catch { }
	}

	function Set-PtSavePathDisplay([string]$p) {
		if ([string]::IsNullOrWhiteSpace($p)) { return }
		$ui.txtSave.Text = $p
		if ($ui.txtSaveFlyout) { $ui.txtSaveFlyout.Text = $p }
		try { Update-SaveOptionsButton } catch { }
	}
	$ui.btnBrowseDir.add_Click({
		$dlg = New-Object System.Windows.Forms.FolderBrowserDialog
		$dlg.Description = 'Choose download folder'
		$cur = [string]$ui.txtSaveFlyout.Text
		if (-not $cur) { $cur = [string]$ui.txtSave.Text }
		if ($cur) { $dlg.SelectedPath = $cur }
		if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
			Set-PtSavePathDisplay $dlg.SelectedPath
		}
	})
	if ($ui.txtSaveFlyout) {
		$ui.txtSaveFlyout.add_LostFocus({
			$p = [string]$ui.txtSaveFlyout.Text
			if ($p) { $ui.txtSave.Text = $p.Trim() }
			try { Update-SaveOptionsButton } catch { }
		})
	}
	$ui.btnAddFile.add_Click({
		$dlg = New-Object System.Windows.Forms.OpenFileDialog
		$dlg.Filter = 'Torrent files (*.torrent)|*.torrent|All files (*.*)|*.*'
		$dlg.Title = 'Add torrent'
		$dlg.Multiselect = $true
		if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
			foreach ($f in @($dlg.FileNames)) { Add-PtTorrent -Source $f }
		}
	})
	$ui.btnAddMagnet.add_Click({
		$ui.txtMagnet.Text = ''
		$ui.popMagnet.PlacementTarget = $ui.btnAddMagnet
		$ui.popMagnet.IsOpen = $true
		$ui.txtMagnet.Focus()
	})
	$ui.btnMagnetOk.add_Click({
		$m = [string]$ui.txtMagnet.Text
		$ui.popMagnet.IsOpen = $false
		if ($m) { Add-PtTorrent -Source $m }
	})
	$ui.btnMagnetCancel.add_Click({ $ui.popMagnet.IsOpen = $false })
	function Update-TransportButtons {
		$vis = [System.Windows.Visibility]::Visible
		$hid = [System.Windows.Visibility]::Collapsed
		$jobs = Get-SelectedJobs
		if ($null -eq $jobs -or $jobs.Count -eq 0) {
			$ui.btnPlayPause.Visibility = $hid
			$ui.btnStop.Visibility = $hid
			$ui.btnRemove.Visibility = $hid
			if ($ui.miCtxPlayPause) { $ui.miCtxPlayPause.Visibility = $hid }
			if ($ui.miCtxStop) { $ui.miCtxStop.Visibility = $hid }
			if ($ui.miCtxRemove) { $ui.miCtxRemove.Visibility = $hid }
			if ($ui.miCtxSep) { $ui.miCtxSep.Visibility = $hid }
			return
		}
		$ui.btnRemove.Visibility = $vis
		if ($ui.miCtxRemove) { $ui.miCtxRemove.Visibility = $vis }
		if ($ui.miCtxSep) { $ui.miCtxSep.Visibility = $vis }
		$anyLive = $false
		$anyActive = $false
		$anyIdlePaused = $false
		foreach ($job in $jobs) {
			$isPaused = [bool]$job.Engine.IsPaused
			$isRunning = [bool]$job.Engine.IsRunning
			if ($isRunning -and -not $isPaused) { $anyActive = $true; $anyLive = $true }
			elseif ($isRunning -and $isPaused) { $anyLive = $true; $anyIdlePaused = $true }
			elseif ([string]$job.Row.Status -eq 'Paused') { $anyIdlePaused = $true }
			else { $anyIdlePaused = $true }
		}
		$playLabel = 'Start'
		$playGeo = $script:PtGeoPlay
		if ($anyActive) {
			$playLabel = 'Pause'
			$playGeo = $script:PtGeoPause
		} elseif ($anyIdlePaused -or $anyLive) {
			$playLabel = 'Resume'
			$playGeo = $script:PtGeoPlay
		}
		$ui.icoPlayPause.Data = $playGeo
		$ui.txtPlayPause.Text = $playLabel
		$ui.btnPlayPause.ToolTip = $playLabel
		$ui.btnPlayPause.Visibility = $vis
		$ui.btnStop.Visibility = $(if ($anyLive) { $vis } else { $hid })
		if ($ui.miCtxPlayPause) {
			$ui.miCtxPlayPause.Header = $playLabel
			$ui.miCtxPlayPause.Visibility = $vis
		}
		if ($ui.icoCtxPlayPause) { $ui.icoCtxPlayPause.Data = $playGeo }
		if ($ui.miCtxStop) { $ui.miCtxStop.Visibility = $(if ($anyLive) { $vis } else { $hid }) }
	}

	function Invoke-PtPlayPause {
		$jobs = Get-SelectedJobs
		if ($null -eq $jobs -or $jobs.Count -eq 0) { return }
		$pause = $false
		foreach ($job in $jobs) {
			if ($job.Engine.IsRunning -and -not $job.Engine.IsPaused) { $pause = $true; break }
		}
		foreach ($job in $jobs) {
			if ($pause) {
				if ($job.Engine.IsRunning -and -not $job.Engine.IsPaused) {
					try { $job.Engine.Pause() } catch { }
				}
			} else {
				if ([string]$job.Row.Status -eq 'Error') {
					try { $job.Engine.Stop() } catch { }
				}
				try { $job.Engine.Resume() } catch { }
			}
			try { $job.Row.Apply($job.Engine.GetStatus()) } catch { }
		}
		try { Update-FilterView } catch { }
		try { Update-TransportButtons } catch { }
		try { Update-UiStatus } catch { }
	}
	function Invoke-PtStop {
		$jobs = Get-SelectedJobs
		if ($null -eq $jobs -or $jobs.Count -eq 0) { return }
		foreach ($job in $jobs) {
			try { $job.Engine.Stop() } catch { }
			try { $job.Row.Apply($job.Engine.GetStatus()) } catch { }
		}
		try { Update-FilterView } catch { }
		try { Update-TransportButtons } catch { }
		try { Update-UiStatus } catch { }
	}
	function Invoke-PtRemove {
		$jobs = Get-SelectedJobs
		if ($null -eq $jobs -or $jobs.Count -eq 0) { return }
		if ($jobs.Count -eq 1) {
			$msg = 'Remove "{0}" from the list?' -f $jobs[0].Row.Name
		} else {
			$msg = 'Remove {0} torrents from the list?' -f $jobs.Count
		}
		$r = Show-PtMessage -Message $msg -Buttons YesNo -CheckLabel 'Also delete downloaded files' -CheckDefault:$false
		if ($r -ne 'Yes') { return }
		$del = [bool]$script:PtDlgChecked
		foreach ($job in $jobs) {
			try { $job.Engine.Stop() } catch { }
			if ($del) {
				try { $job.Engine.DeleteDownloadedFiles() } catch { }
			}
			[void]$script:PtJobs.Remove($job)
			[void]$script:PtRows.Remove($job.Row)
		}
		try { Update-TransportButtons } catch { }
		try { Update-UiStatus } catch { }
	}

	$ui.btnPlayPause.add_Click({ Invoke-PtPlayPause })
	$ui.btnStop.add_Click({ Invoke-PtStop })
	$ui.btnRemove.add_Click({ Invoke-PtRemove })
	if ($ui.miCtxPlayPause) { $ui.miCtxPlayPause.add_Click({ Invoke-PtPlayPause }) }
	if ($ui.miCtxStop) { $ui.miCtxStop.add_Click({ Invoke-PtStop }) }
	if ($ui.miCtxRemove) { $ui.miCtxRemove.add_Click({ Invoke-PtRemove }) }
	$ui.lvTorrents.add_ContextMenuOpening({
		param($sender, $e)
		$row = $null
		try {
			$pos = [System.Windows.Input.Mouse]::GetPosition($ui.lvTorrents)
			$hit = [System.Windows.Media.VisualTreeHelper]::HitTest($ui.lvTorrents, $pos)
			$cur = $null
			if ($hit) { $cur = $hit.VisualHit }
			while ($null -ne $cur) {
				if ($cur -is [System.Windows.Controls.ListViewItem]) {
					$row = $cur.DataContext
					break
				}
				try { $cur = [System.Windows.Media.VisualTreeHelper]::GetParent($cur) } catch { break }
			}
		} catch { }
		if ($row) {
			$already = $false
			try { $already = $ui.lvTorrents.SelectedItems.Contains($row) } catch { }
			if (-not $already) { $ui.lvTorrents.SelectedItem = $row }
		}
		$jobs = Get-SelectedJobs
		if ($null -eq $jobs -or $jobs.Count -eq 0) {
			$e.Handled = $true
			return
		}
		try { Update-TransportButtons } catch { }
	})
	$ui.lstFilter.add_SelectionChanged({ try { Update-FilterView } catch { } })
	function Set-PtFilterCollapsed([bool]$collapsed) {
		$script:PtFilterCollapsed = [bool]$collapsed
		$hid = [System.Windows.Visibility]::Collapsed
		$vis = [System.Windows.Visibility]::Visible
		foreach ($item in $ui.lstFilter.Items) {
			$sp = $null
			try { $sp = $item.Content } catch { }
			if ($sp -isnot [System.Windows.Controls.StackPanel]) { continue }
			if ($sp.Children.Count -gt 1) {
				$sp.Children[1].Visibility = $(if ($collapsed) { $hid } else { $vis })
			}
			if ($sp.Children.Count -gt 0 -and $sp.Children[0] -is [System.Windows.Shapes.Path]) {
				if ($collapsed) {
					$sp.Children[0].Margin = New-Object System.Windows.Thickness 0
				} else {
					$sp.Children[0].Margin = New-Object System.Windows.Thickness 0,0,8,0
				}
			}
		}
		switch ($collapsed) {
			$true {
				$ui.colFilter.Width = New-Object System.Windows.GridLength 40
				$ui.icoFilterFold.Data = $script:PtGeoChevronRight
				$ui.btnFilterFold.ToolTip = 'Show filters'
			}
			$false {
				$ui.colFilter.Width = New-Object System.Windows.GridLength 150
				$ui.icoFilterFold.Data = $script:PtGeoChevronLeft
				$ui.btnFilterFold.ToolTip = 'Hide filters'
			}
		}
	}
	$ui.btnFilterFold.add_Click({
		switch ([bool]$script:PtFilterCollapsed) {
			$true  { Set-PtFilterCollapsed $false }
			$false { Set-PtFilterCollapsed $true }
		}
	})
	$ui.lvTorrents.add_SelectionChanged({
		$script:PtDetailId = ''
		try { Update-TransportButtons } catch { }
		try { Update-UiStatus } catch { }
	})
	$ui.lvTorrents.add_KeyDown({
		param($sender, $e)
		$ctrl = [bool]([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)
		if ($ctrl -and $e.Key -eq [System.Windows.Input.Key]::A) {
			try { $ui.lvTorrents.SelectAll() } catch { }
			$e.Handled = $true
			return
		}
		if ($e.Key -eq [System.Windows.Input.Key]::Delete) {
			Invoke-PtRemove
			$e.Handled = $true
		}
	})
	$ui.btnRegister.add_Click({
		try {
			Register-PowerTorrentAssociations
			Update-AssocLabel
			Show-PtMessage -Message "magnet: links for this Windows user now open PowerTorrent.`nYou can test from a browser or by clicking a magnet URI." | Out-Null
		} catch {
			Show-PtMessage -Message ([string]$_) | Out-Null
		}
	})
	$ui.btnRegisterTorrent.add_Click({
		try {
			Register-PowerTorrentAssociations -IncludeTorrentFiles
			Update-AssocLabel
			Show-PtMessage -Message ".torrent files for this Windows user now open PowerTorrent.`nWindows 10/11 may still need Open with if another app is the default." | Out-Null
		} catch {
			Show-PtMessage -Message ([string]$_) | Out-Null
		}
	})
	$ui.btnUnregister.add_Click({
		Unregister-PowerTorrentAssociations
		Update-AssocLabel
		Show-PtMessage -Message "Removed this user's magnet: / PowerTorrent .torrent associations." | Out-Null
	})

	function Update-MaxCaptionIcon {
		if ($window.WindowState -eq [System.Windows.WindowState]::Maximized) {
			$ui.pathWinMax.Data = $script:PtGeomRestore
			$ui.btnWinMax.ToolTip = 'Restore'
		} else {
			$ui.pathWinMax.Data = $script:PtGeomMax
			$ui.btnWinMax.ToolTip = 'Maximize'
		}
	}

	$ui.btnOptions.add_Click({
		switch ([bool]$ui.popOptions.IsOpen) {
			$true  { $ui.popOptions.IsOpen = $false }
			$false {
				if ($ui.txtSaveFlyout) { $ui.txtSaveFlyout.Text = $ui.txtSave.Text }
				$ui.popOptions.IsOpen = $true
			}
		}
	})
	$window.add_PreviewMouseLeftButtonDown({
		param($sender, $e)
		if (-not [bool]$ui.popOptions.IsOpen) { return }
		if ([bool]$ui.btnOptions.IsMouseOver) { return }
		$child = $ui.popOptions.Child
		if ($null -ne $child -and [bool]$child.IsMouseOver) { return }
		if ($ui.cmbTheme -and [bool]$ui.cmbTheme.IsDropDownOpen) { return }
		$ui.popOptions.IsOpen = $false
	})
	function Hide-PtToTray {
		if ($script:PtInTray -or $script:PtHidingToTray) { return }
		$script:PtHidingToTray = $true
		try {
			$window.ShowInTaskbar = $false
			if ($window.WindowState -ne [System.Windows.WindowState]::Minimized) {
				$window.WindowState = [System.Windows.WindowState]::Minimized
			}
			$script:PtInTray = $true
			if ($script:PtNotify) {
				$script:PtNotify.Visible = $true
				try {
					$script:PtNotify.ShowBalloonTip(2500, 'PowerTorrent', 'PowerTorrent is minimized to the notification area.', [System.Windows.Forms.ToolTipIcon]::Info)
				} catch { }
			}
		} finally {
			$script:PtHidingToTray = $false
		}
	}
	function Show-PtFromTray {
		if ($script:PtHidingToTray) { return }
		$script:PtInTray = $false
		if ($script:PtNotify) { try { $script:PtNotify.Visible = $false } catch { } }
		$window.ShowInTaskbar = $true
		$window.WindowState = [System.Windows.WindowState]::Normal
		try { [void]$window.Activate() } catch { }
		try { Update-MaxCaptionIcon } catch { }
	}
	function Exit-PtFromTray {
		$script:PtReallyExit = $true
		try { $window.DialogResult = $true } catch {
			try { $window.Close() } catch { }
		}
	}

	Add-Type -AssemblyName System.Drawing | Out-Null
	$script:PtReallyExit = $false
	$script:PtInTray = $false
	$script:PtHidingToTray = $false
	try {
		$ni = New-Object System.Windows.Forms.NotifyIcon
		$ni.Text = 'PowerTorrent'
		$ni.Visible = $false
		if ($script:PtTrayIdle) { $ni.Icon = $script:PtTrayIdle }
		else { $ni.Icon = [System.Drawing.SystemIcons]::Application }
		$cm = New-Object System.Windows.Forms.ContextMenu
		$miShow = New-Object System.Windows.Forms.MenuItem 'Show PowerTorrent'
		$miExit = New-Object System.Windows.Forms.MenuItem 'Exit'
		[void]$cm.MenuItems.Add($miShow)
		[void]$cm.MenuItems.Add($miExit)
		$ni.ContextMenu = $cm
		$miShow.add_Click({ Show-PtFromTray })
		$miExit.add_Click({ Exit-PtFromTray })
		$ni.add_DoubleClick({ Show-PtFromTray })
		$script:PtNotify = $ni
	} catch {
		$script:PtNotify = $null
	}

	$ui.btnWinMin.add_Click({ Hide-PtToTray })
	$ui.btnWinMax.add_Click({
		if ($window.WindowState -eq [System.Windows.WindowState]::Maximized) {
			$window.WindowState = [System.Windows.WindowState]::Normal
		} else {
			$window.WindowState = [System.Windows.WindowState]::Maximized
		}
		Update-MaxCaptionIcon
	})
	$ui.btnWinClose.add_Click({
		if ($ui.chkCloseToTray -and [bool]$ui.chkCloseToTray.IsChecked) {
			Hide-PtToTray
			return
		}
		Exit-PtFromTray
	})
	$ui.btnWinClose.add_MouseEnter({
		try { [PowerTorrent.ThemeUtil]::SetPathStrokeRgb($ui.pathWinClose, 255, 255, 255) } catch { }
	})
	$ui.btnWinClose.add_MouseLeave({
		try { [PowerTorrent.ThemeUtil]::SetPathStrokeKey($ui.pathWinClose, $window.Resources, 'Theme.Text') } catch { }
	})

	$ui.hdrBar.add_MouseLeftButtonDown({
		param($sender, $e)
		if ($e.ChangedButton -ne [System.Windows.Input.MouseButton]::Left) { return }
		if ($e.ClickCount -ge 2) {
			if ($window.WindowState -eq [System.Windows.WindowState]::Maximized) {
				$window.WindowState = [System.Windows.WindowState]::Normal
			} else {
				$window.WindowState = [System.Windows.WindowState]::Maximized
			}
			Update-MaxCaptionIcon
			return
		}
		try { $window.DragMove() } catch { }
	})
	$window.add_StateChanged({
		Update-MaxCaptionIcon
		if ($script:PtHidingToTray) { return }
		if ($window.WindowState -eq [System.Windows.WindowState]::Minimized) {
			Hide-PtToTray
		}
	})

	$timer = New-Object System.Windows.Threading.DispatcherTimer
	$timer.Interval = [TimeSpan]::FromMilliseconds(200)
	$timer.add_Tick({ Update-UiStatus })
	$timer.Start()

	$planetTimer = New-Object System.Windows.Threading.DispatcherTimer
	$planetTimer.Interval = [TimeSpan]::FromMilliseconds(140)
	$planetTimer.add_Tick({
		if (-not $script:PtPlanetFrames -or $script:PtPlanetFrames.Count -eq 0) { return }
		if (-not $script:PtPlanetConnected) {
			if ($script:PtPlanetIdle) { $ui.imgPlanet.Source = $script:PtPlanetIdle }
			$script:PtPlanetIndex = 2
			return
		}
		$script:PtPlanetIndex = ($script:PtPlanetIndex + 1) % $script:PtPlanetFrames.Count
		$ui.imgPlanet.Source = $script:PtPlanetFrames[$script:PtPlanetIndex]
	})
	$planetTimer.Start()

	$window.add_Closing({
		param($sender, $e)
		if (-not $script:PtReallyExit -and $ui.chkCloseToTray -and [bool]$ui.chkCloseToTray.IsChecked) {
			$e.Cancel = $true
			Hide-PtToTray
			return
		}
		try { $timer.Stop() } catch { }
		try { $planetTimer.Stop() } catch { }
		try { Stop-AllTorrents } catch { }
		try { [PowerTorrent.VpnHub]::Stop() } catch { }
		if ($script:PtNotify) {
			try { $script:PtNotify.Visible = $false } catch { }
			try { $script:PtNotify.Dispose() } catch { }
			$script:PtNotify = $null
		}
		if ($script:PtMutex) {
			try { [void]$script:PtMutex.ReleaseMutex() } catch { }
			try { $script:PtMutex.Dispose() } catch { }
		}
	})

	try { Update-TransportButtons } catch { }

	if ($AutoStart -and $InitialSource) {
		$window.add_ContentRendered({
			Add-PtTorrent -Source $InitialSource
		})
	}

	try {
		[void]$window.ShowDialog()
	} catch {
		$dump = Join-Path $env:TEMP 'pt-gui-fail.txt'
		[System.IO.File]::WriteAllText($dump, $_.Exception.ToString())
		throw
	}
}

# --- main ---
Initialize-PowerTorrentEngine
$script:PtTheme = 'Ice'
$script:PtCloseToTray = $false
$script:PtVpnRequire = $true
$script:PtVpnAuto = $true
Import-PtIniToSession
if (-not $script:PtTheme) { $script:PtTheme = 'Ice' }
if ($SelfTest) {
	$fail = [PowerTorrent.Engine]::SelfTest()
	if ($fail) {
		Write-Host "SELFTEST FAILED: $fail" -ForegroundColor Red
		exit 1
	}
	Write-Host 'SELFTEST OK' -ForegroundColor Green
	exit 0
}

if ($Unregister) {
	Unregister-PowerTorrentAssociations
	Write-Host 'Removed current-user magnet: / PowerTorrent .torrent associations.' -ForegroundColor Green
	exit 0
}

if ($Register) {
	if (-not (Confirm-PowerTorrentNotice)) { exit 1 }
	if ($MagnetOnly) { Register-PowerTorrentAssociations }
	else { Register-PowerTorrentAssociations -IncludeTorrentFiles }
	Write-Host 'Registered PowerTorrent as the magnet: handler for this Windows user.' -ForegroundColor Green
	if (-not $MagnetOnly) {
		Write-Host 'Also registered .torrent files (Windows may still ask you to confirm the default app).' -ForegroundColor Green
	}
	Write-Host ('Command: {0}' -f (Get-PowerTorrentLaunchCommand)) -ForegroundColor DarkGray
	exit 0
}

Initialize-PtVpn

try {
	[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

if ($Torrent -and $Torrent.Trim().ToLowerInvariant().StartsWith('magnet:')) {
	$Magnet = $Torrent
	$Torrent = ''
}

$isMagnet = -not [string]::IsNullOrWhiteSpace($Magnet)
$source = ''
if ($isMagnet) { $source = $Magnet.Trim() }
elseif ($Torrent) { $source = $Torrent }

$useGui = -not [bool]$NoGui -and -not [bool]$ListOnly

if ($useGui) {
	if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
		$exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
		$argList = New-Object System.Collections.Generic.List[string]
		[void]$argList.Add('-STA')
		[void]$argList.Add('-NoProfile')
		[void]$argList.Add('-ExecutionPolicy')
		[void]$argList.Add('Bypass')
		[void]$argList.Add('-File')
		[void]$argList.Add((Get-PowerTorrentScriptPath))
		foreach ($k in $PSBoundParameters.Keys) {
			$v = $PSBoundParameters[$k]
			if ($v -is [Management.Automation.SwitchParameter]) {
				if ($v) { [void]$argList.Add("-$k") }
			} else {
				[void]$argList.Add("-$k")
				[void]$argList.Add([string]$v)
			}
		}
		$p = Start-Process -FilePath $exe -ArgumentList $argList.ToArray() -Wait -PassThru
		exit $p.ExitCode
	}
	$save = $SavePath
	if ([string]::IsNullOrWhiteSpace($save)) { $save = Get-DefaultSavePath }
	$auto = -not [string]::IsNullOrWhiteSpace($source)
	$createdNew = $false
	$script:PtMutex = New-Object System.Threading.Mutex($false, 'Local\PowerTorrent.Gui', [ref]$createdNew)
	if (-not $createdNew) {
		if ($source) { Send-PtInbox $source }
		try { $script:PtMutex.Dispose() } catch { }
		exit 0
	}
	try { [void]$script:PtMutex.WaitOne(0) } catch { }
	if (-not (Confirm-PowerTorrentNotice -Gui)) {
		try { [void]$script:PtMutex.ReleaseMutex() } catch { }
		try { $script:PtMutex.Dispose() } catch { }
		exit 1
	}
	Show-PowerTorrentGui -InitialSource $source -InitialSave $save -AutoStart:$auto
	exit 0
}

if (-not $isMagnet -and -not $Torrent) {
	$Torrent = Select-TorrentFile
	if (-not $Torrent) {
		Write-Host 'No torrent file selected. Exiting.' -ForegroundColor Yellow
		exit 0
	}
	$source = $Torrent
}

if (-not $isMagnet) {
	$source = [System.IO.Path]::GetFullPath($source)
	if (-not (Test-Path -LiteralPath $source)) {
		throw "Torrent file not found: $source"
	}
}

if ([string]::IsNullOrWhiteSpace($SavePath)) {
	if ($isMagnet) { $SavePath = Get-DefaultSavePath }
	else { $SavePath = [System.IO.Path]::GetDirectoryName($source) }
}

if (-not (Confirm-PowerTorrentNotice)) { exit 1 }

Write-Host ''
Write-Host '  PowerTorrent 1.3	|  Windows PowerShell 5.1  |  no dependencies' -ForegroundColor Cyan
Write-Host '  =================================================================' -ForegroundColor Cyan

$cfg = New-PowerTorrentSettings -Source $source -OutDir $SavePath -ListenPort $Port -Peers $MaxPeers `
	-Dht (-not [bool]$NoDht) -Encrypt (-not [bool]$NoEncrypt) -Utp (-not [bool]$NoUtp) `
	-Seq ([bool]$Sequential) -Seed (-not [bool]$NoSeed) -Forced $Peer -Level $LogLevel
$engine = [PowerTorrent.Engine]::new($cfg)
$info = $engine.GetInfo()
Show-TorrentInfo $info
Write-Host ("  Save path  : {0}" -f $cfg.SavePath) -ForegroundColor DarkGray
Write-Host ''

if ($ListOnly) {
	if ($isMagnet) {
		Write-Host 'ListOnly: magnet metadata is not fetched. Run without -ListOnly to download.' -ForegroundColor Yellow
	} else {
		Write-Host 'ListOnly: not starting download.' -ForegroundColor Yellow
	}
	exit 0
}

Start-PowerTorrentConsole -engine $engine
if ($Host.Name -eq 'Windows PowerShell ISE Host') {
	Start-Sleep -Seconds 3
}
