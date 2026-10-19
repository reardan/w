import java.awt.image.BufferedImage;
import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import javax.imageio.ImageIO;

/**
 * Launcher icon resources for tools/android/build.w --icon, from one PNG.
 * Run with the JDK's single-file launcher (no packages or downloads):
 *
 *   java -Djava.awt.headless=true tools/android/icon/WIcon.java icon.png res/ [#RRGGBB]
 *
 * Writes mipmap-{m,h,xh,xxh,xxxh}dpi/w_app_icon.png (48 dp legacy icons),
 * adaptive foreground and monochrome layers (108 dp), drawable-*dpi/
 * w_notification.png (24 dp, white glyph), values/w_icon.xml (background
 * color) and mipmap-anydpi-v26/w_app_icon.xml.
 *
 * A "tile" icon (an opaque, mostly one-color shape around a glyph, like the
 * wed icon) becomes background color plus glyph: the tile fills the 72 dp
 * visible area and the glyph keeps its proportions. Other icons are scaled
 * into the 66 dp safe zone over the background color (default white).
 */
public final class WIcon {
    private static final String[] DENSITIES = {"mdpi", "hdpi", "xhdpi", "xxhdpi", "xxxhdpi"};
    private static final double[] SCALES = {1, 1.5, 2, 3, 4};

    /** Straight (non-premultiplied) RGBA in 0..1. */
    private static final class Image {
        final int width, height;
        final float[] rgba;
        Image(int width, int height) { this.width = width; this.height = height; rgba = new float[width * height * 4]; }
    }

    public static void main(String[] args) throws IOException {
        if (args.length < 2) {
            System.err.println("usage: WIcon icon.png res-dir [#RRGGBB]");
            System.exit(2);
        }
        BufferedImage input = ImageIO.read(new File(args[0]));
        if (input == null) throw new IOException("Not a readable image: " + args[0]);
        Image source = load(input);
        int[] box = opaqueBounds(source);
        if (box == null) throw new IOException("Icon is fully transparent: " + args[0]);
        float[] tile = tileColor(source, box);
        float[] background = args.length > 2 ? parseColor(args[2]) : tile != null ? tile : new float[]{1, 1, 1};
        // Foreground: the glyph alone for tiles, otherwise the whole icon.
        Image foreground = tile != null ? glyph(source, box, background) : source;
        Image mono = monochrome(foreground);
        int[] glyphBox = opaqueBounds(mono);
        File res = new File(args[1]);
        for (int i = 0; i < DENSITIES.length; i++) {
            double s = SCALES[i];
            int legacy = (int) Math.round(48 * s), layer = (int) Math.round(108 * s), small = (int) Math.round(24 * s);
            String mipmap = "mipmap-" + DENSITIES[i], drawable = "drawable-" + DENSITIES[i];
            // Legacy icon: the original artwork as drawn.
            write(fit(source, new int[]{0, 0, source.width, source.height}, legacy, legacy, false), res, mipmap, "w_app_icon.png");
            // Tiles fill the 72 dp visible area; free-form art stays inside the 66 dp safe zone.
            double content = (tile != null ? 72 : 66) * s;
            write(fit(foreground, box, layer, content, true), res, mipmap, "w_app_icon_foreground.png");
            write(fit(mono, box, layer, content, true), res, mipmap, "w_app_icon_monochrome.png");
            if (glyphBox != null) write(fit(mono, glyphBox, small, 20 * s, true), res, drawable, "w_notification.png");
        }
        text(res, "values", "w_icon.xml", "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<resources>\n"
            + "    <color name=\"w_icon_background\">" + hex(background) + "</color>\n</resources>\n");
        text(res, "mipmap-anydpi-v26", "w_app_icon.xml", "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
            + "<adaptive-icon xmlns:android=\"http://schemas.android.com/apk/res/android\">\n"
            + "    <background android:drawable=\"@color/w_icon_background\" />\n"
            + "    <foreground android:drawable=\"@mipmap/w_app_icon_foreground\" />\n"
            + "    <monochrome android:drawable=\"@mipmap/w_app_icon_monochrome\" />\n"
            + "</adaptive-icon>\n");
        System.out.println("icon: " + (tile != null ? "tile " + hex(background) + " + glyph" : "free-form on " + hex(background)));
    }

    private static Image load(BufferedImage input) {
        Image image = new Image(input.getWidth(), input.getHeight());
        for (int y = 0; y < image.height; y++)
            for (int x = 0; x < image.width; x++) {
                int argb = input.getRGB(x, y), at = (y * image.width + x) * 4;
                image.rgba[at] = ((argb >> 16) & 255) / 255f;
                image.rgba[at + 1] = ((argb >> 8) & 255) / 255f;
                image.rgba[at + 2] = (argb & 255) / 255f;
                image.rgba[at + 3] = ((argb >>> 24) & 255) / 255f;
            }
        return image;
    }

    private static int[] opaqueBounds(Image image) {
        int left = image.width, top = image.height, right = -1, bottom = -1;
        for (int y = 0; y < image.height; y++)
            for (int x = 0; x < image.width; x++)
                if (image.rgba[(y * image.width + x) * 4 + 3] > 0.02f) {
                    left = Math.min(left, x); right = Math.max(right, x);
                    top = Math.min(top, y); bottom = Math.max(bottom, y);
                }
        return right < 0 ? null : new int[]{left, top, right - left + 1, bottom - top + 1};
    }

    private static float distance(float[] a, int at, float[] b) {
        float r = a[at] - b[0], g = a[at + 1] - b[1], bl = a[at + 2] - b[2];
        return (float) Math.sqrt(r * r + g * g + bl * bl);
    }

    /** The tile's color when a ring just inside the opaque bounds is opaque and one color. */
    private static float[] tileColor(Image image, int[] box) {
        int inset = Math.max(1, Math.min(box[2], box[3]) / 25);
        int x0 = box[0] + inset, y0 = box[1] + inset, x1 = box[0] + box[2] - 1 - inset, y1 = box[1] + box[3] - 1 - inset;
        if (x1 <= x0 || y1 <= y0) return null;
        java.util.ArrayList<Integer> ring = new java.util.ArrayList<>();
        for (int x = x0; x <= x1; x++) { ring.add(y0 * image.width + x); ring.add(y1 * image.width + x); }
        for (int y = y0; y <= y1; y++) { ring.add(y * image.width + x0); ring.add(y * image.width + x1); }
        float[] sum = new float[3];
        int opaque = 0;
        for (int index : ring)
            if (image.rgba[index * 4 + 3] > 0.9f) {
                opaque++;
                for (int c = 0; c < 3; c++) sum[c] += image.rgba[index * 4 + c];
            }
        if (opaque < ring.size() * 0.9) return null;
        float[] mean = {sum[0] / opaque, sum[1] / opaque, sum[2] / opaque};
        int near = 0;
        for (int index : ring) if (image.rgba[index * 4 + 3] > 0.9f && distance(image.rgba, index * 4, mean) < 0.1f) near++;
        return near >= ring.size() * 0.8 ? mean : null;
    }

    /** Pixels that differ from the tile color, un-mixed from it at anti-aliased edges. */
    private static Image glyph(Image image, int[] box, float[] background) {
        float far = 0;
        for (int y = box[1]; y < box[1] + box[3]; y++)
            for (int x = box[0]; x < box[0] + box[2]; x++) {
                int at = (y * image.width + x) * 4;
                if (image.rgba[at + 3] > 0.9f) far = Math.max(far, distance(image.rgba, at, background));
            }
        Image out = new Image(image.width, image.height);
        if (far < 0.05f) return out;
        for (int i = 0; i < image.width * image.height; i++) {
            int at = i * 4;
            float t = Math.min(1, distance(image.rgba, at, background) / far) * image.rgba[at + 3];
            if (t <= 0.004f) continue;
            for (int c = 0; c < 3; c++)
                out.rgba[at + c] = Math.max(0, Math.min(1, (image.rgba[at + c] - (1 - t) * background[c]) / t));
            out.rgba[at + 3] = t;
        }
        return out;
    }

    private static Image monochrome(Image image) {
        Image out = new Image(image.width, image.height);
        for (int i = 0; i < image.width * image.height; i++) {
            out.rgba[i * 4] = out.rgba[i * 4 + 1] = out.rgba[i * 4 + 2] = 1;
            out.rgba[i * 4 + 3] = image.rgba[i * 4 + 3];
        }
        return out;
    }

    /**
     * Area-averages source rectangle box (premultiplied) onto a size x size canvas.
     * centered: the box's longer side spans `content` pixels, centered; otherwise
     * the box is stretched to the canvas (size and content give width and height).
     */
    private static Image fit(Image image, int[] box, int size, double content, boolean centered) {
        int width = size, height = centered ? size : (int) Math.round(content);
        double scale = centered ? content / Math.max(box[2], box[3]) : (double) width / box[2];
        double scaleY = centered ? scale : (double) height / box[3];
        double left = centered ? (width - box[2] * scale) / 2 : 0, top = centered ? (height - box[3] * scaleY) / 2 : 0;
        // Horizontal pass over the box rows, then vertical.
        float[] rows = new float[width * box[3] * 4];
        for (int y = 0; y < box[3]; y++)
            for (int x = 0; x < width; x++) {
                double a = box[0] + (x - left) / scale, b = box[0] + (x + 1 - left) / scale;
                accumulate(image.rgba, (box[1] + y) * image.width, 1, box[0], box[0] + box[2], a, b, rows, (y * width + x) * 4, true);
            }
        Image out = new Image(width, height);
        for (int x = 0; x < width; x++)
            for (int y = 0; y < height; y++) {
                double a = (y - top) / scaleY, b = (y + 1 - top) / scaleY;
                accumulate(rows, x, width, 0, box[3], a, b, out.rgba, (y * width + x) * 4, false);
            }
        for (int i = 0; i < width * height; i++) {
            float alpha = out.rgba[i * 4 + 3];
            for (int c = 0; c < 3; c++) out.rgba[i * 4 + c] = alpha > 0 ? Math.min(1, out.rgba[i * 4 + c] / alpha) : 0;
        }
        return out;
    }

    /** Weighted average of pixels [a, b) along one axis (pixels outside [lo, hi) count as transparent). */
    private static void accumulate(float[] src, int base, int stride, int lo, int hi, double a, double b,
                                   float[] dst, int at, boolean premultiply) {
        double span = b - a;
        if (span <= 0) return;
        float r = 0, g = 0, bl = 0, alpha = 0;
        for (int i = (int) Math.max(lo, Math.floor(a)); i < Math.min(hi, Math.ceil(b)); i++) {
            double weight = (Math.min(b, i + 1) - Math.max(a, i)) / span;
            if (weight <= 0) continue;
            int p = (base + i * stride) * 4;
            float m = premultiply ? src[p + 3] : 1;
            r += weight * src[p] * m; g += weight * src[p + 1] * m; bl += weight * src[p + 2] * m;
            alpha += weight * src[p + 3];
        }
        dst[at] = r; dst[at + 1] = g; dst[at + 2] = bl; dst[at + 3] = alpha;
    }

    private static void write(Image image, File res, String folder, String name) throws IOException {
        BufferedImage out = new BufferedImage(image.width, image.height, BufferedImage.TYPE_INT_ARGB);
        for (int y = 0; y < image.height; y++)
            for (int x = 0; x < image.width; x++) {
                int at = (y * image.width + x) * 4;
                int argb = channel(image.rgba[at + 3]) << 24 | channel(image.rgba[at]) << 16
                    | channel(image.rgba[at + 1]) << 8 | channel(image.rgba[at + 2]);
                out.setRGB(x, y, argb);
            }
        File directory = new File(res, folder);
        if (!directory.isDirectory() && !directory.mkdirs()) throw new IOException("Cannot create " + directory);
        if (!ImageIO.write(out, "png", new File(directory, name))) throw new IOException("No PNG writer");
    }

    private static int channel(float value) { return Math.max(0, Math.min(255, Math.round(value * 255))); }

    private static void text(File res, String folder, String name, String content) throws IOException {
        File directory = new File(res, folder);
        if (!directory.isDirectory() && !directory.mkdirs()) throw new IOException("Cannot create " + directory);
        Files.write(new File(directory, name).toPath(), content.getBytes(StandardCharsets.UTF_8));
    }

    private static float[] parseColor(String text) {
        if (!text.matches("#[0-9a-fA-F]{6}")) throw new IllegalArgumentException("Icon background must be #RRGGBB: " + text);
        int rgb = Integer.parseInt(text.substring(1), 16);
        return new float[]{((rgb >> 16) & 255) / 255f, ((rgb >> 8) & 255) / 255f, (rgb & 255) / 255f};
    }

    private static String hex(float[] color) {
        return String.format("#%02X%02X%02X", channel(color[0]), channel(color[1]), channel(color[2]));
    }
}
