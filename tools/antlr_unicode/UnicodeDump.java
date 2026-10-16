import java.util.*;
import java.lang.reflect.*;
import org.antlr.v4.unicode.UnicodeData;
import org.antlr.v4.runtime.misc.IntervalSet;
import org.antlr.v4.runtime.misc.Interval;
public class UnicodeDump {
 public static void main(String[] args) throws Exception {
  Field f=UnicodeData.class.getDeclaredField("propertyCodePointRanges"); f.setAccessible(true);
  Map<String,IntervalSet> p=(Map<String,IntervalSet>)f.get(null);
  Field a=UnicodeData.class.getDeclaredField("propertyAliases"); a.setAccessible(true);
  Map<String,String> aliases=(Map<String,String>)a.get(null);
  for (String key:new TreeSet<String>(p.keySet())) {
   System.out.print("P\t"+key);
   for (Interval i:p.get(key).getIntervals()) System.out.print("\t"+i.a+":"+i.b);
   System.out.println();
  }
  for (String key:new TreeSet<String>(aliases.keySet())) System.out.println("A\t"+key+"\t"+aliases.get(key));
  for (int c=0;c<=0x10ffff;c++) {
   int lo=Character.toLowerCase(c), hi=Character.toUpperCase(c);
   if(c!=lo || c!=hi) System.out.println("C\t"+c+"\t"+lo+"\t"+hi);
  }
 }
}
