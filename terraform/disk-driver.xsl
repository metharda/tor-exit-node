<?xml version="1.0"?>
<!-- The provider declares file-attached disks as raw; the VM disk is a qcow2
     overlay on the Ubuntu cloud image, so set its driver type to qcow2. -->
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:output omit-xml-declaration="yes" indent="yes"/>
  <xsl:template match="node()|@*">
    <xsl:copy>
      <xsl:apply-templates select="node()|@*"/>
    </xsl:copy>
  </xsl:template>
  <xsl:template match="/domain/devices/disk[@device='disk']/driver/@type">
    <xsl:attribute name="type">qcow2</xsl:attribute>
  </xsl:template>
</xsl:stylesheet>
